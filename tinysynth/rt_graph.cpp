// ================================================================
// rt_graph.cpp
// Description : runtime DSP engine and realtime audio backend
// ================================================================
//
// On the Haskell side, compilation ends at TemplateGraph (an ordered
// ensemble of per-template RuntimeGraphs). On the C++ side, this file
// turns each template into preallocated NodeSpec state, hosts a vector
// of GraphInstances (running copies of each template) sharing a single
// Server bus pool, and runs them in compile-decreed template order
// every block.

#include "rt_graph.h"

#include <q/fx/biquad.hpp>
#include <q/fx/delay.hpp>
#include <q/support/duration.hpp>
#include <q/support/phase.hpp>
#include <q/synth/envelope_gen.hpp>
#include <q/synth/noise_gen.hpp>
#include <q/synth/saw_osc.hpp>
#include <q/synth/sin_osc.hpp>
#include <q_io/audio_device.hpp>
#include <q_io/audio_stream.hpp>

#include <portaudio.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>
#include <span>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace q = cycfi::q;

struct RTGraph;

/* Note [Dense runtime model]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The runtime operates entirely on dense indices.

The Haskell compiler performs the decisive symbolic -> dense lowering:

  NodeID    -> NodeIndex
  Port name -> PortIndex

By the time control reaches this file, there is no symbolic lookup,
no map from user-facing names to nodes, and no scheduling work left to
perform.

This matters for both simplicity and safety.

The small wrapper structs below preserve nominal distinctions between
node positions, port positions, and control slots.
*/

namespace {

// Default sample rate used before a realtime device is opened.
// TODO: make this configurable
constexpr float kDefaultSampleRate = 48000.0f;

// §2.E: release-then-free silence detection.
// kReleaseSilenceThreshold is the absolute peak below which a single
// block is considered "silent" for the purposes of auto-freeing a
// Releasing instance. -80 dBFS is well below the noise floor of any
// realistic signal chain.
// kReleaseSilenceBlocks is the consecutive-quiet-blocks window the
// instance must clear before its slot is reclaimed. At 48 kHz with
// 256-sample blocks this is ~43 ms, comfortably more than typical
// envelope tails after the released level reaches the threshold.
// See Note [§2.E: release-then-free instance lifecycle].
constexpr float kReleaseSilenceThreshold = 1e-4f;
constexpr int   kReleaseSilenceBlocks    = 8;

// Lifecycle state for a GraphInstance. "Dead" is not represented here
// — a dead slot is a std::optional<GraphInstance> with no value, which
// is observably distinct from any InstanceStatus.
//
// The integer values are part of the C ABI returned by
// rt_graph_instance_status; do not renumber.
enum class InstanceStatus : int {
  Live      = 0,  // default; gate-on / sustaining
  Releasing = 1,  // release requested; processing continues until silent
};

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

[[nodiscard]] constexpr bool valid(NodeIndex x) noexcept { return x.value >= 0; }
[[nodiscard]] constexpr bool valid(PortIndex x) noexcept { return x.value >= 0; }
[[nodiscard]] constexpr bool valid(ControlIndex x) noexcept { return x.value >= 0; }

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
NodeKind must align with the integer tags emitted by the compiler.

  Haskell (MetaSonic.Types.kindTag)    C++ (NodeKind)
  ---------------------------------    --------------
  kindTag KSinOsc       = 1            SinOsc        = 1
  kindTag KOut          = 2            Out           = 2
  kindTag KGain         = 3            Gain          = 3
  kindTag KSawOsc       = 5            SawOsc        = 5
  kindTag KNoiseGen     = 6            NoiseGen      = 6
  kindTag KLPF          = 7            LPF           = 7
  kindTag KAdd          = 8            Add           = 8
  kindTag KEnv          = 9            Env           = 9
  kindTag KBusOut       = 10           BusOut        = 10
  kindTag KBusIn        = 11           BusIn         = 11
  kindTag KBusInDelayed = 12           BusInDelayed  = 12
  kindTag KDelay        = 13           Delay        = 13

  Bus model: Out, BusOut, BusIn, and BusInDelayed all operate on the
  same bus pool, owned by the Server (see Note [§2.C: server-global
  buses]). The pool is double-buffered (server.output_buses for the
  current block and server.output_buses_prev for the previous block's
  snapshot). Out and BusOut share the same kernel writing to
  output_buses — Out is just a source-level alias for "BusOut to a
  hardware-routed bus". The audio callback routes buses
  [0..output_channels-1] to hardware regardless of which kind wrote
  them. BusIn reads from the live output_buses; BusInDelayed reads
  from the frozen output_buses_prev snapshot.

  Same-cycle ordering between BusOut/Out and BusIn within one instance
  is enforced on the Haskell side via E_r edges in effectiveDeps;
  BusInDelayed deliberately produces no E_r edge so feedback loops
  are schedulable. See Note [Effect-induced edges (E_r)] in
  MetaSonic.Bridge.Validate and Note [Bus pool double-buffering]
  below.

  Cross-instance routing (§2.C): because the bus pool is shared,
  voice A writing bus 5 is visible to voice B's BusIn(5) within the
  same block (assuming A's Out runs before B's BusIn — which holds
  if A's template precedes B's in g.defs ordering and the per-instance
  topological order respects bus E_r edges).

  Cross-template ordering (§2.D.3): the template execution order in
  g.defs is the order produced by Haskell's compileTemplateGraph,
  which topologically sorts templates by inter-template bus precedence
  (T_a precedes T_b iff bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅). The runtime
  has no scheduling logic of its own — it just iterates g.defs in
  registration order, and registration order equals execution order
  by Haskell-side construction. See Note [Multi-template execution
  loop] below.

  Delay model: Delay nodes own per-instance fractional ring buffers
  (q::delay). No shared resource, no Eff annotation beyond Pure. See
  Note [Per-node delay state] below.
*/

enum class NodeKind : int {
  SinOsc       = 1,
  Out          = 2,
  Gain         = 3,
  SawOsc       = 5,
  NoiseGen     = 6,
  LPF          = 7,
  Add          = 8,
  Env          = 9,
  BusOut       = 10,
  BusIn        = 11,
  BusInDelayed = 12,
  Delay        = 13,
};

// Single source of truth for the integer-tag → NodeKind mapping.
// Both rt_graph_add_node and rt_graph_kind_supported go through this,
// so the C ABI's "is this tag known" answer cannot drift from the
// dispatch table.
[[nodiscard]] constexpr std::optional<NodeKind>
kind_from_tag(int node_kind) noexcept {
  switch (node_kind) {
  case 1:  return NodeKind::SinOsc;
  case 2:  return NodeKind::Out;
  case 3:  return NodeKind::Gain;
  case 5:  return NodeKind::SawOsc;
  case 6:  return NodeKind::NoiseGen;
  case 7:  return NodeKind::LPF;
  case 8:  return NodeKind::Add;
  case 9:  return NodeKind::Env;
  case 10: return NodeKind::BusOut;
  case 11: return NodeKind::BusIn;
  case 12: return NodeKind::BusInDelayed;
  case 13: return NodeKind::Delay;
  default: return std::nullopt;
  }
}

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

// Shared oscillator phase state. q::phase_iterator owns the 1.31 fixed-point
// accumulator and per-sample increment. Fixed-point phase wraps at 2pi with
// uint32 overflow — no fmod, no conditional branch.
//
// *Osc oscillators differ only in waveshaping function, not in
// phase-accumulation state, so all Osc nodes use OscState.
struct OscState {
  q::phase_iterator phase_iter;
};

struct NoiseGenState {
  q::white_noise_gen noise;
};

// LPF holds a q::lowpass biquad and the last-applied freq/q so the filter is
// _only_ reconfigured when a parameter changes (block-rate). last_freq/last_q
// are initialised to -1 so the first process call reconfigures with the node's
// controls.
struct LPFState {
  q::lowpass filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
  double last_freq = -1.0;
  double last_q = -1.0;
};

/* Note [Envelope state]
~~~~~~~~~~~~~~~~~~~~~~~~
EnvState wraps q::adsr_envelope_gen plus the bookkeeping needed for the
runtime's reconfigure-on-change discipline:

  * 'env' — the q ADSR generator. Constructed lazily on first process() so
    we can hand it the active sample rate rather than kDefaultSampleRate.
  * 'last_*' — the last A/D/S/R/sps values applied to the ramp segments.
    Initialised to -1 so the first process call reconfigures the segments
    against the current controls.
  * 'prev_gate' — sample-by-sample edge detection. A rising edge calls
    env.attack(), a falling edge calls env.release(). The threshold is
    fixed at 0.5 so a gate held at @Param 1@ stays in attack/decay/sustain
    until a downward transition.

q::adsr_envelope_gen owns four segments (attack, decay, sustain, release).
We expose attack/decay/release rates and a linear sustain *level* — not q's
own decibel sustain_level setter, which writes to the wrong segment. We set
segment[1].level() (decay's destination, equal to the sustain plateau)
directly. The sustain *rate* (q's slow background fade during sustain) is
held at the q default of 50 s.
*/
struct EnvState {
  std::optional<q::adsr_envelope_gen> env;
  double last_a = -1.0;
  double last_d = -1.0;
  double last_s = -1.0;
  double last_r = -1.0;
  float last_sps = -1.0f;
  float prev_gate = 0.0f;
};

/* Note [Per-node delay state]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Delay nodes own a fractional ring buffer (q::delay = basic_delay over
fractional_ring_buffer<float> with linear interpolation). The buffer
is sized by control[0] (the compile-time max delay in seconds, sent
from the Haskell side via UGenView's controls list). The actual delay
time is control[1] (when port 1 is unconnected) or input port 1 read
per sample (audio-rate modulation).

The buffer is built lazily on first process() — same pattern as Env
and LPF — so we have the active sample rate. last_max_time and
last_sps memos drive a rebuild when either changes, which is
extremely rare on the audio path (sample rate is fixed once audio is
opened, max delay never changes for a compiled graph). The rebuild
loses any prior buffer contents; this is acceptable because it only
happens when the delay's geometry changes, which is at graph load.

Per-instance buffer means there's no shared resource: Eff is Pure on
the Haskell side, no E_r edges, scheduling is pure-data-dependency.
Multi-instance and multi-template both preserve this — each
GraphInstance has its own DelayState regardless of which template it
belongs to.
*/
struct DelayState {
  std::optional<q::delay> line;
  double last_max_time = -1.0;
  float  last_sps      = -1.0f;
};

// Stateless nodes use monostate: this keeps each runtime node from dealing
// directly with every possible state object.
using NodeState =
    std::variant<std::monostate, OscState, NoiseGenState, LPFState, EnvState, DelayState>;

/* Note [Spec/state split: NodeSpec vs NodeInstanceState]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each node's *spec* (immutable per template) is separated from its
*state* (mutable per instance):

  * NodeSpec — the parts that don't change as the graph runs: the
    kind tag, the input-port wiring (input_refs) set by
    rt_graph_connect / rt_graph_template_connect, and the control
    defaults inherited from configure_spec (and optionally overridden
    by rt_graph_template_set_default). One NodeSpec is shared across
    every GraphInstance of the same MetaDef.

  * NodeInstanceState — the parts each instance owns: its current
    control values (initialised from the spec's defaults; mutable
    via rt_graph_instance_set_control), per-port output buffers
    preallocated to max_frames, and the kernel state variant
    (OscState, LPFState, …).

§2.B made the multi-instance shape concrete: a single MetaDef hosts
a vector of GraphInstances. §2.C moved the bus pool out of the
GraphInstance into a Server shared by all instances of an RTGraph,
enabling cross-voice routing (voice A writes bus 5; voice B's
BusIn(5) reads it within the same block). §2.D.3 takes the next step:
RTGraph holds a *vector* of MetaDefs (templates), and each
GraphInstance carries a template_id naming the MetaDef it was created
from. The bus pool stays at the Server level — it's shared across all
instances of all templates, which is what makes cross-template routing
work the same way cross-instance routing does within a single template.

Convention used throughout the kernels:

    auto &node = inst.nodes[node_idx];

destructures the per-instance node state at the top. The NodeSpec is
read indirectly via resolve_input(g, inst, node_idx, …) which looks
up the right MetaDef from inst.template_id; node.controls /
node.outputs / node.state are read and written directly.
g.server.output_buses / g.server.output_buses_prev are accessed by the
bus-write/bus-read kernels.
*/

struct NodeSpec {
  NodeKind kind = NodeKind::Out;
  std::vector<double> default_controls;
  std::vector<InputRef> input_refs;
};

struct NodeInstanceState {
  std::vector<double> controls;
  std::vector<std::vector<float>> outputs;
  NodeState state{};
};

// View one output buffer as a span over the first nframes samples.
[[nodiscard]] static std::span<float>
output_span(NodeInstanceState &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(), static_cast<std::size_t>(nframes)};
}

[[nodiscard]] static std::span<const float>
output_span(const NodeInstanceState &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(), static_cast<std::size_t>(nframes)};
}

/* Note [§2.C: server-global buses]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The bus pool is owned by a Server that is shared across all
GraphInstances of an RTGraph. The two parallel vectors
(output_buses and output_buses_prev) hold the live and
previous-block contents respectively, double-buffered exactly as
before — but now the swap+clear runs *once per block* at the Server
level, before any instance processes.

This unlocks cross-voice routing. Voice A's BusOut(5) writes into
server.output_buses[5]; voice B's BusIn(5) (in a later instance,
same block) reads it back. For cross-block feedback or "send
return" patterns where A and B run in any order, B uses
BusInDelayed(5) and reads from output_buses_prev[5].

§2.D.3 multi-template extension: the Server is *also* shared across
templates. A template T_a's BusOut(5) and a peer template T_b's
BusIn(5) hit the same server.output_buses[5] just as if the writes
came from sibling instances of the same template. The Haskell side's
compileTemplateGraph guarantees T_a precedes T_b in the execution
order whenever T_b reads what T_a writes (live), so the writes are
visible by the time the reads run. Cross-template feedback (cycles in
the precedence DAG) is rejected at compile time; the user's remedy is
to switch one of the live reads to BusInDelayed, which reads from
output_buses_prev and breaks the cycle across the block boundary.

In SuperCollider terms, the Server's output_buses corresponds to the
private/output bus space that all Synths share.
*/

struct Server {
  std::vector<std::vector<float>> output_buses;
  std::vector<std::vector<float>> output_buses_prev;
};

/* Note [MetaDef and GraphInstance]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
MetaDef is the immutable template:

  * max_frames — the per-block buffer size every NodeInstanceState's
    outputs were sized to at init time. All instances of the same
    MetaDef share this max_frames.
  * nodes — vector of NodeSpec, parallel to GraphInstance::nodes by
    NodeIndex.

GraphInstance is one running copy:

  * template_id — dense index into RTGraph::defs naming which MetaDef
    this instance was created from. Set at make_instance time and
    never changes for the life of the instance. Drives the dispatch
    in process_instance and the spec lookup in resolve_input.
  * nodes — parallel-by-index vector of per-node mutable state.

The bus pool is *not* on GraphInstance — it lives on the Server,
shared across instances regardless of template. See Note [§2.C:
server-global buses].

§2.D.3: the (template_id, GraphInstance) pair lets the runtime's
process_graph iterate templates in execution order outer × instances
inner. A GraphInstance never references the MetaDef directly; it goes
through g.defs[template_id] every time, so reallocating g.defs
(growing the vector when more templates are registered) doesn't
invalidate any instance — pointers into MetaDef would, instance_id +
template_id is stable.
*/

struct MetaDef {
  int max_frames = 0;
  std::vector<NodeSpec> nodes;
};

struct GraphInstance {
  // Template this instance was created from. Indexes into
  // RTGraph::defs. Set by make_instance and immutable thereafter.
  int template_id = 0;

  std::vector<NodeInstanceState> nodes;

  // §2.E lifecycle state. Default-constructed instances are Live.
  // rt_graph_instance_release flips the status to Releasing and the
  // process_graph loop reclaims the slot once the instance has been
  // silent (peak < kReleaseSilenceThreshold) for kReleaseSilenceBlocks
  // consecutive blocks. See Note [§2.E: release-then-free instance
  // lifecycle].
  InstanceStatus status = InstanceStatus::Live;

  // Consecutive blocks (while Releasing) the instance has produced a
  // peak below kReleaseSilenceThreshold. Reset to 0 every time the
  // instance is *not* quiet for a block, and on transition into
  // Releasing.
  int silent_blocks = 0;

  // Per-block peak |input| accumulated by the Out and BusOut kernels
  // for this instance. Reset to 0 at the top of each block by
  // process_instance and updated by process_out. Read by process_graph
  // when status == Releasing to drive the silence counter. The peak is
  // measured at the *sink* (Out / BusOut) so it captures the instance's
  // actual contribution to the bus pool rather than internal node
  // activity that may be silenced downstream.
  float block_sink_peak = 0.0f;
};

/* Note [Node configuration: spec vs state]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Adding a node decomposes into two independent steps:

  configure_spec(spec, kind)
    sets the immutable layout — kind tag, default control values,
    input_refs vector sized to the kind's input arity. Writes once
    per add_node, even when many GraphInstances exist.

  init_node_state(node, spec, max_frames)
    builds the per-instance state for a single NodeInstanceState
    based on the spec — chooses the state-variant alternative,
    sizes the output-buffer vector and preallocates each buffer to
    max_frames, and copies the spec's default_controls into the
    instance's controls. Called once per (instance × node).

The architectural invariant is that the DSP loop performs no
allocation. All buffer growth happens here while loading or
reloading the graph, or while creating an instance. Bus-pool growth
happens on the Server, not on instances; see ensure_output_bus_count.
*/

static void configure_spec(NodeSpec &spec, NodeKind kind) {
  spec.kind = kind;
  spec.default_controls.clear();
  spec.input_refs.clear();

  switch (kind) {
  case NodeKind::SinOsc:
    spec.default_controls.resize(2, 0.0); // [freq, initial_phase]
    spec.input_refs.resize(2);            // [freq_in, phase_in]
    break;

  case NodeKind::Out:
    spec.default_controls.resize(1, 0.0); // [bus]
    spec.input_refs.resize(1);            // [signal_in]
    break;

  case NodeKind::Gain:
    spec.default_controls.resize(1, 1.0); // [gain_amount]
    spec.input_refs.resize(2);            // [signal_in, gain_in]
    break;

  case NodeKind::SawOsc:
    spec.default_controls.resize(2, 0.0); // [freq, initial_phase]
    spec.input_refs.resize(2);            // [freq_in, phase_in]
    break;

  case NodeKind::NoiseGen:
    // No controls, no inputs — pure source
    break;

  case NodeKind::LPF:
    spec.default_controls = {1000.0, 0.707}; // [cutoff_freq, q]
    spec.input_refs.resize(3);               // [signal_in, freq_in, q_in]
    break;

  case NodeKind::Add:
    spec.default_controls.resize(2, 0.0); // [a_default, b_default]
    spec.input_refs.resize(2);            // [a_in, b_in]
    break;

  case NodeKind::Env:
    // [gate_default, attack_s, decay_s, sustain_lin, release_s]
    spec.default_controls = {0.0, 0.01, 0.05, 0.5, 0.1};
    spec.input_refs.resize(1);            // [gate_in]
    break;

  case NodeKind::BusOut:
    // BusOut is a sink, like Out: control 0 = bus index, one input,
    // no per-node output buffer (writes directly into
    // server.output_buses). See Note [Bus model].
    spec.default_controls.resize(1, 0.0); // [bus]
    spec.input_refs.resize(1);            // [signal_in]
    break;

  case NodeKind::BusIn:
    // BusIn is a source: control 0 = bus index, no inputs, one
    // output buffer that downstream nodes can read.
    spec.default_controls.resize(1, 0.0); // [bus]
    break;

  case NodeKind::BusInDelayed:
    // Shaped exactly like BusIn (1 control [bus], 0 inputs, 1
    // output) but the kernel reads from the previous-block snapshot
    // instead of the live pool. See Note [Bus pool double-buffering].
    spec.default_controls.resize(1, 0.0); // [bus]
    break;

  case NodeKind::Delay:
    // Per-node fractional delay line. controls[0] is the max delay
    // time in seconds; controls[1] is the delay-time default. Two
    // audio inputs: [signal, delay_time]. One output (configured at
    // init_node_state time). State is the q::delay instance,
    // allocated lazily once we know the active sample rate.
    spec.default_controls = {0.2, 0.0};   // [max_time_s, delay_time_s]
    spec.input_refs.resize(2);            // [signal_in, time_in]
    break;
  }
}

static void init_node_state(NodeInstanceState &node, const NodeSpec &spec, int max_frames) {
  node.state = std::monostate{};
  node.outputs.clear();

  switch (spec.kind) {
  case NodeKind::SinOsc:
  case NodeKind::SawOsc:
    node.outputs.resize(1);
    node.state = OscState{};
    break;

  case NodeKind::NoiseGen:
    node.outputs.resize(1);
    node.state = NoiseGenState{};
    break;

  case NodeKind::LPF:
    node.outputs.resize(1);
    node.state = LPFState{};
    break;

  case NodeKind::Env:
    node.outputs.resize(1);
    node.state = EnvState{};
    break;

  case NodeKind::Delay:
    node.outputs.resize(1);
    node.state = DelayState{};
    break;

  case NodeKind::Gain:
  case NodeKind::Add:
  case NodeKind::BusIn:
  case NodeKind::BusInDelayed:
    node.outputs.resize(1);
    break;

  case NodeKind::Out:
  case NodeKind::BusOut:
    // Sinks: no per-node output buffer. Writes go directly into
    // server.output_buses inside the bus-write kernel.
    break;
  }

  // Per-instance controls take their initial values from the spec's
  // defaults. rt_graph_instance_set_control later writes here,
  // leaving the spec untouched.
  node.controls = spec.default_controls;

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
  * copy each Server output bus onto q_io's non-interleaved output
    channel spans
  * set a one-way "started" flag once the callback has actually run

Crucially, the callback does not call back into the Haskell side,
take locks, or perform configuration work. The stream is just a realtime
pull wrapper around the already-constructed RTGraph.
*/

struct GraphAudioStream : q::audio_stream {
  GraphAudioStream(
      RTGraph &graph, q::audio_device const &device, std::size_t output_channels
  );

  void process(out_channels const &out) override;
  bool wait_started(std::chrono::milliseconds timeout) noexcept;

  RTGraph &graph;
  std::atomic<bool> started{false};
};

} // namespace

/* Note [RTGraph ownership]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
RTGraph is the sole owner of runtime state.

Today (§2.D.3) it owns:

  * a vector of MetaDefs — one per registered template, in execution
    order. Templates are appended via rt_graph_template_add (or
    auto-created at index 0 by the legacy single-template ABI). The
    Haskell side guarantees registration order equals execution order
    by feeding templates to the FFI in the order produced by
    compileTemplateGraph. The runtime never reorders.
  * a vector of GraphInstances — running copies of any template,
    each carrying its template_id. The slot index is the instance_id
    exposed to the Haskell side; freed slots are reused. Live and
    dead slots coexist (std::optional).
  * one Server holding the shared bus pool (output_buses +
    output_buses_prev), used by every instance of every template.
  * the maximum frame size used for all preallocations.
  * the currently active sample rate.
  * an optional realtime audio stream.

The Haskell side sees RTGraph only as an opaque pointer.
All ownership, lifetime, and mutation live here.

Legacy single-template back-compat: the existing ABI surface
(rt_graph_add_node, rt_graph_set_control, rt_graph_connect,
rt_graph_instance_add without a template argument) operates on
template 0, which rt_graph_create / rt_graph_clear materialise as an
empty MetaDef so legacy callers don't need to issue an explicit
rt_graph_template_add. See Note [Legacy single-template ABI as
template-0 shim].
*/

/* Note [Bus pool double-buffering]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The server bus pool is split into two parallel vectors of identical shape:

  * output_buses       — this block's *live* contents. BusOut/Out
                         accumulate into it; BusIn reads from it.
  * output_buses_prev  — the *previous* block's snapshot, frozen for
                         the duration of the current block.
                         BusInDelayed reads from this.

At the start of every block (in process_graph) we:

  1. swap(output_buses, output_buses_prev). After the swap, the
     vector that was "live" last block is now the "prev" snapshot,
     and the vector that *was* "prev" (whose data is two blocks old)
     is recycled as the new "live" buffer.
  2. zero the new live buffer (clear_output_buses). BusOut accumulates
     additively, so it needs to start from zero.

The swap runs *once per block* at the Server level — every instance
processed in this block sees the same prev snapshot and writes into
the same live buffer. Cross-instance and cross-template routing
follow directly: A's BusOut(5) and B's BusIn(5) hit the same
server.output_buses[5] regardless of whether A and B are sibling
instances of one template or instances of different templates.

Within a block, reads and writes have well-defined origins:

  - BusOut writes go into server.output_buses[bus].
  - BusIn reads from server.output_buses[bus]. Within one instance
    the Haskell scheduler's E_r edges force every same-bus
    BusOut/Out to execute before BusIn, so by the time an
    intra-instance BusIn runs the live buffer holds this block's
    accumulated value. Cross-instance, ordering depends on the
    enclosing template's position in g.defs (templates execute in
    registration order, and Haskell's compileTemplateGraph put
    writers before readers).
  - BusInDelayed reads from server.output_buses_prev[bus]. No E_r
    edge relates BusInDelayed to BusOut: the snapshot is immutable
    for the duration of the block. BusInDelayed can therefore appear
    *before* same-bus BusOut in the topological order, which is
    exactly what makes feedback loops schedulable across blocks
    (and across instances, and across templates).

On the very first block, output_buses_prev contains the
zero-initialised state assigned by ensure_output_bus_count, so a
first-block BusInDelayed produces silence. After block N completes,
its writes become block N+1's "prev" snapshot.

Memory cost: 2× the bus pool, total. With 64 buses × 1024 frames ×
4 bytes that's 512 KB regardless of how many instances or templates
run — instances and templates are stateful but bus-pool-free.

ensure_output_bus_count grows both vectors in lockstep so the swap
never needs to reconcile sizes. rt_graph_clear empties both.

In SuperCollider terms, output_buses corresponds to In.ar's source
and output_buses_prev corresponds to InFeedback.ar's source.
*/

struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  float sample_rate = kDefaultSampleRate;
  // §2.D.3: vector of MetaDefs (templates). Index i is template_id i,
  // and the iteration order in process_graph is i ascending — i.e.
  // registration order is execution order. The Haskell side
  // (compileTemplateGraph) picks registration order to match the
  // topo-sort over template precedence.
  std::vector<MetaDef> defs;
  // GraphInstances live in a flat vector regardless of template.
  // Each GraphInstance carries its template_id; process_graph filters
  // by it to group instances per template. Slot index is the
  // instance_id exposed at the C ABI; std::optional models live/dead.
  std::vector<std::optional<GraphInstance>> instances;
  Server server;
  std::unique_ptr<GraphAudioStream> audio;
};

namespace {

// Lookup a template's MetaDef by id. Returns nullptr for negative /
// out-of-range ids.
[[nodiscard]] static MetaDef *
template_at(RTGraph &g, int template_id) noexcept {
  if (template_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(template_id);
  if (idx >= g.defs.size()) return nullptr;
  return &g.defs[idx];
}

[[nodiscard]] static const MetaDef *
template_at(const RTGraph &g, int template_id) noexcept {
  if (template_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(template_id);
  if (idx >= g.defs.size()) return nullptr;
  return &g.defs[idx];
}

// Lookup an instance by id. Returns nullptr for negative / out-of-range
// / dead-slot ids.
[[nodiscard]] static GraphInstance *
instance_at(RTGraph &g, int instance_id) noexcept {
  if (instance_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g.instances.size()) return nullptr;
  if (!g.instances[idx].has_value()) return nullptr;
  return &*g.instances[idx];
}

[[nodiscard]] static const GraphInstance *
instance_at(const RTGraph &g, int instance_id) noexcept {
  if (instance_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g.instances.size()) return nullptr;
  if (!g.instances[idx].has_value()) return nullptr;
  return &*g.instances[idx];
}

// Resolve one connected input to the source node's output span.
// An empty span means the input is unavailable and the caller should
// fall back to the corresponding control value or silence.
//
// §2.D.3: the spec lookup goes through inst.template_id rather than a
// fixed g.def. Each kernel reads sources from its own instance's
// nodes (cross-instance signal flow goes through the server bus pool
// via BusOut/BusIn, not through direct port wiring) and reads the
// wiring from the *template* that instance belongs to. Wiring is
// per-template, state is per-instance.
[[nodiscard]] static std::span<const float> resolve_input(
    const RTGraph &g,
    const GraphInstance &inst,
    std::size_t dst_idx,
    PortIndex input_index,
    int nframes
) noexcept {
  if (!valid(input_index)) {
    return {};
  }

  const MetaDef *def = template_at(g, inst.template_id);
  if (!def) {
    return {};
  }

  if (dst_idx >= def->nodes.size()) {
    return {};
  }

  const NodeSpec &dst_spec = def->nodes[dst_idx];
  const std::size_t idx = to_size(input_index);
  if (idx >= dst_spec.input_refs.size()) {
    return {};
  }

  const InputRef &ref = dst_spec.input_refs[idx];
  if (!valid(ref.src_node) || !valid(ref.src_port)) {
    return {};
  }

  const std::size_t src_index = to_size(ref.src_node);
  if (src_index >= inst.nodes.size()) {
    return {};
  }

  const NodeInstanceState &src = inst.nodes[src_index];
  const std::size_t src_port = to_size(ref.src_port);
  if (src_port >= src.outputs.size()) {
    return {};
  }

  if (src.outputs[src_port].size() < static_cast<std::size_t>(nframes)) {
    return {};
  }

  return output_span(src, ref.src_port, nframes);
}

// Forward decl so add_node helpers can grow the server's bus pool.
static void ensure_output_bus_count(Server &server, std::size_t count, int max_frames);

// Ensure template `template_id`'s spec vector and every live instance
// of that template have a state slot at node_index. Both halves are
// grown in lockstep so the parallel-by-index invariant
// (def.nodes[i] describes the spec, every instance's nodes[i] holds
// its state) is preserved per-template.
//
// Instances of *other* templates are left alone — node_index N in
// template A is unrelated to node_index N in template B; each
// template has its own dense node space.
static void ensure_node_slot(RTGraph &g, int template_id, NodeIndex node_index) {
  if (!valid(node_index)) {
    return;
  }
  MetaDef *def = template_at(g, template_id);
  if (!def) {
    return;
  }

  const std::size_t idx = to_size(node_index);
  if (def->nodes.size() <= idx) {
    def->nodes.resize(idx + 1);
  }
  for (auto &maybe_inst : g.instances) {
    if (!maybe_inst) continue;
    if (maybe_inst->template_id != template_id) continue;
    if (maybe_inst->nodes.size() <= idx) {
      maybe_inst->nodes.resize(idx + 1);
    }
  }
}

/* Note [Output bus semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Out nodes do not write directly to a hardware device.

Each Out node accumulates its input signal directly into one Server
output bus, selected by control slot 0.

This gives the runtime a useful intermediate abstraction:

  * multiple Out nodes (within one instance, across many instances of
    one template, or across instances of different templates) may sum
    onto the same bus
  * offline processing can inspect buses without opening audio
  * realtime output can map buses to device channels in a separate step

The bus vectors are preallocated exactly like node outputs, so clearing
and accumulation remain allocation-free inside the DSP loop.
*/

// Grow both halves of the double-buffered bus pool to hold at least
// `count` buses. The two vectors must always be the same size so the
// per-block std::swap in process_graph stays size-consistent. New
// slots are zero-initialised on both sides — a first-block
// BusInDelayed reading from output_buses_prev therefore gets silence
// rather than uninitialised memory. See Note [Bus pool
// double-buffering].
static void ensure_output_bus_count(Server &server, std::size_t count, int max_frames) {
  if (server.output_buses.size() >= count) {
    return;
  }

  const std::size_t old_size = server.output_buses.size();
  server.output_buses.resize(count);
  server.output_buses_prev.resize(count);
  for (std::size_t i = old_size; i < count; ++i) {
    server.output_buses[i].resize(static_cast<std::size_t>(max_frames), 0.0f);
    server.output_buses_prev[i].resize(static_cast<std::size_t>(max_frames), 0.0f);
  }
}

// Zero the first nframes of each *live* output bus before one block
// render. The previous-block snapshot (output_buses_prev) is left
// alone — that's the buffer BusInDelayed is reading from, and any
// writes to it would corrupt feedback paths. See Note [Bus pool
// double-buffering].
static void clear_output_buses(Server &server, int nframes) noexcept {
  const std::size_t frames = static_cast<std::size_t>(nframes);
  for (auto &bus : server.output_buses) {
    std::fill_n(bus.begin(), frames, 0.0f);
  }
}

void set_osc_initial_phase(NodeInstanceState &node, double value) noexcept {
  auto *osc = std::get_if<OscState>(&node.state);
  assert(osc && "oscillator node has non-oscillator state");
  if (!osc) {
    return;
  }

  const double frac = std::isfinite(value) ? value - std::floor(value) : 0.0;

  // Note [Phase setting semantics]
  // q::phase_iterator has no public API for setting _phase independently of _step.
  // phase_iterator::set(freq, sps) updates only _step.
  // operator=(phase) also sets _step, not _phase — a counterintuitive trap.
  //
  // Let's keep this direct field access here so a Q API change breaks in one place...
  osc->phase_iter._phase = q::frac_to_phase(frac);
}

/* Note [SinOsc processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
SinOsc uses q::phase_iterator for phase accumulation and q::sin as
sample-computing function.

  * q::phase uses a 1.31 fixed-point format (uint32). The uint32 range maps to
    one cycle (0–2pi), overflow wraps phase naturally with no fmod or
    conditional branch.

  * phase_iterator::set updates the per-sample increment (_step) from a
    frequency, leaving the accumulated phase (_phase) untouched. We exploit
    that for both the constant and modulated paths.

  * q::sin is a lookup-table sine that carries no mutable state.

When port 0 (frequency) is wired to another node's output, the kernel
runs sample-accurately: phase_iter.set() is called every sample with
the modulator's value, then phase is advanced and the sine is read.
This is the FM path. When port 0 is unconnected, the kernel sets the
phase increment once per block from the control default — same cost as
before.

The phase port (port 1) is currently consumed only as an initial-phase
control via set_osc_initial_phase at graph load. Wiring an audio source
to port 1 has no effect today; phase modulation (PM) needs a separate
runtime path that adds to _phase per sample.
*/

static void process_sinosc(const RTGraph &g, GraphInstance &inst,
                           std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  auto *osc = std::get_if<OscState>(&node.state);
  assert(osc && "SinOsc node has non-oscillator state");
  if (!osc) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  if (!freq_in.empty()) {
    // Sample-accurate FM: update the phase increment per sample.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      osc->phase_iter.set(
          q::frequency{static_cast<double>(freq_in[fi])}, g.sample_rate);
      out[fi] = q::sin(osc->phase_iter++);
    }
  } else {
    // Constant frequency: set the increment once per block.
    const double freq = node.controls[0];
    osc->phase_iter.set(q::frequency{freq}, g.sample_rate);
    for (int i = 0; i < nframes; ++i) {
      out[static_cast<std::size_t>(i)] = q::sin(osc->phase_iter++);
    }
  }
}

/* Note [SawOsc processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

SawOsc is just like SinOsc: q::phase_iterator accumulates phase across blocks
and q::saw computes the sample using poly-BLEP antialiasing. The phase_iterator
supplies both the current phase and the per-sample step (dt) for the BLEP
correction term, so updating freq via phase_iter.set() also refreshes dt for
the BLEP — no separate bookkeeping needed.

Frequency follows the same rule as SinOsc: when port 0 is wired, the kernel
updates phase_iter per sample (sample-accurate FM); otherwise the increment
is set once per block from the control default.

Phase port (port 1) is initial-only, same as SinOsc.
*/

static void process_sawosc(const RTGraph &g, GraphInstance &inst,
                           std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  auto *osc = std::get_if<OscState>(&node.state);
  assert(osc && "SawOsc node has non-oscillator state");
  if (!osc) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  if (!freq_in.empty()) {
    // Sample-accurate FM: update the phase increment per sample.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      osc->phase_iter.set(
          q::frequency{static_cast<double>(freq_in[fi])}, g.sample_rate);
      out[fi] = q::saw(osc->phase_iter++);
    }
  } else {
    // Constant frequency: set the increment once per block.
    const double freq = node.controls[0];
    osc->phase_iter.set(q::frequency{freq}, g.sample_rate);
    for (int i = 0; i < nframes; ++i) {
      out[static_cast<std::size_t>(i)] = q::saw(osc->phase_iter++);
    }
  }
}

/* Note [NoiseGen processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NoiseGen uses q::white_noise_gen, a fast xorshift PRNG. The generator state
persists across blocks, so the noise stream is continuous.

q's white_noise_gen documents its output as [-1, 1] but the implementation
multiplies an unsigned uint32 by `2.0 / UINT32_MAX`, producing values in
[0, 2] with mean +1 — the standard "fast whitenoise" trick relies on
casting to int32 first (see vendor/q/q_lib/include/q/synth/noise_gen.hpp).
Subtracting 1 here re-centers the output to bipolar [-1, 1] without
modifying upstream q code. A future upstream fix would let us drop the
correction.

No controls or inputs.
*/

static void process_noisegen(const RTGraph &, GraphInstance &inst,
                             std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  auto *noisegen = std::get_if<NoiseGenState>(&node.state);
  assert(noisegen && "NoiseGen node has non-noisegen state");
  if (!noisegen) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  for (int i = 0; i < nframes; ++i) {
    out[static_cast<std::size_t>(i)] = noisegen->noise() - 1.0f;
  }
}

/* Note [LPF processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

LPF uses q::lowpass, a biquad IIR low-pass filter (Audio-EQ Cookbook).

Cutoff frequency and q are block-latched: read once per block from an input port
if connected, otherwise from the control defaults. The filter should be
reconfigured via biquad::config when parameters change, but reconfiguration updates
the five coefficients without resetting the delay state, so there is no
discontinuity beyond the filter's own transient.

If the signal input is unconnected, output is silence.
*/

static void process_lpf(const RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);
  const auto q_in = resolve_input(g, inst, node_idx, PortIndex{2}, nframes);

  const double freq = !freq_in.empty() ? static_cast<double>(freq_in[0]) : node.controls[0];
  const double q_val = !q_in.empty() ? static_cast<double>(q_in[0]) : node.controls[1];

  auto *lpf = std::get_if<LPFState>(&node.state);
  assert(lpf && "LPF node has non-LPF state");
  if (!lpf) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  if (freq != lpf->last_freq || q_val != lpf->last_q) {
    lpf->filter.config(
        q::frequency{freq}, g.sample_rate, q_val
    );
    lpf->last_freq = freq;
    lpf->last_q = q_val;
  }

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = lpf->filter(sig_in[fi]);
  }
}

/* Note [Gain processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Gain is sample-accurate when port 1 is wired to another node's output:
both signal and modulator are read per sample, so this is the
ring-modulation / AM path. When port 1 is unconnected, the kernel falls
back to the scalar control default for the whole block.

If the signal input (port 0) is unconnected, output is silence.
*/

static void process_gain(const RTGraph &g, GraphInstance &inst,
                         std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  const auto gain_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  if (!gain_in.empty()) {
    // Sample-accurate gain: read modulator per sample.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      out[fi] = sig_in[fi] * gain_in[fi];
    }
  } else {
    // Constant gain from the control default.
    const float amount = static_cast<float>(node.controls[0]);
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      out[fi] = sig_in[fi] * amount;
    }
  }
}

/* Note [Add processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Add is a sample-accurate two-input sum. Either input may be wired to
another node's output (read per sample) or left unconnected (in which
case the corresponding control default is used as a constant).

The control defaults come from any 'Param' literals on the source side:
@add 440.0 mod@ lowers to an Add node with control[0]=440.0 and port 1
wired to mod, so the kernel computes 440.0 + mod[i] per sample. This is
the canonical bias use case (turning a bipolar modulator into a
modulated frequency or amplitude).
*/

static void process_add(const RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto a_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  const auto b_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);

  const float a_const = static_cast<float>(node.controls[0]);
  const float b_const = static_cast<float>(node.controls[1]);

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    const float a = !a_in.empty() ? a_in[fi] : a_const;
    const float b = !b_in.empty() ? b_in[fi] : b_const;
    out[fi] = a + b;
  }
}

/* Note [Envelope processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The envelope kernel does three things per block:

  1. Reconfigure the q ramp segments if A/D/S/R or sps changed since the
     last block (block-rate parameter latching, same idiom as LPF).
  2. Walk the gate input sample-by-sample, calling env.attack() on a rising
     edge and env.release() on a falling edge. The gate falls back to the
     control default (slot 0) if no audio source is wired, so 'env (Param 1)
     ...' holds the gate high for the duration of the graph.
  3. Sample the envelope on every step and write to the output buffer.

The envelope_gen is constructed lazily on first call, against the runtime's
current sample rate — kDefaultSampleRate is a placeholder that may be wrong
once realtime audio opens with a different rate.
*/
static void process_env(const RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);

  auto *st = std::get_if<EnvState>(&node.state);
  assert(st && "Env node has non-Env state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  const auto gate_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  const float gate_default = static_cast<float>(node.controls[0]);
  const double a_sec = node.controls[1];
  const double d_sec = node.controls[2];
  const double s_lin = node.controls[3];
  const double r_sec = node.controls[4];

  // (Re)build the envelope_gen against the active sample rate on first
  // call or after a sample-rate change.
  if (!st->env || st->last_sps != g.sample_rate) {
    st->env.emplace(q::adsr_envelope_gen::config{}, g.sample_rate);
    st->last_sps = g.sample_rate;
    st->last_a = st->last_d = st->last_s = st->last_r = -1.0;
  }

  if (a_sec != st->last_a) {
    st->env->attack_rate(q::duration{a_sec}, g.sample_rate);
    st->last_a = a_sec;
  }
  if (d_sec != st->last_d) {
    st->env->decay_rate(q::duration{d_sec}, g.sample_rate);
    st->last_d = d_sec;
  }
  if (s_lin != st->last_s) {
    // Set decay's destination level — the actual sustain plateau. q's own
    // sustain_level() setter writes to segment[2] (the slow sustain decay's
    // endpoint, =0 by default) which is not what callers want.
    (*st->env)[1].level(static_cast<float>(s_lin));
    st->last_s = s_lin;
  }
  if (r_sec != st->last_r) {
    st->env->release_rate(q::duration{r_sec}, g.sample_rate);
    st->last_r = r_sec;
  }

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    const float gate = !gate_in.empty() ? gate_in[fi] : gate_default;

    if (st->prev_gate <= 0.5f && gate > 0.5f) {
      st->env->attack();
    } else if (st->prev_gate > 0.5f && gate <= 0.5f) {
      st->env->release();
    }
    st->prev_gate = gate;

    out[fi] = (*st->env)();
  }
}

/* Note [Bus-write kernel: Out and BusOut share this]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Out and BusOut are operationally identical: both accumulate their input
signal additively into 'g.server.output_buses[bus]', where 'bus' is
read from control slot 0. The only difference is at the *source* level
— Out reads as "final hardware output", BusOut reads as "intermediate
audio bus". The audio callback routes buses [0..output_channels-1] to
hardware regardless of which kind wrote them, so an Out targeting bus
5 and a BusOut targeting bus 5 produce identical audible results.

Both kinds dispatch to this single kernel ('process_out') from
process_instance. See Note [Bus model] near the NodeKind enum.

The kernel performs no allocation: the bus pool was sized at graph
load via 'ensure_output_bus_count' inside
'rt_graph_instance_set_control', and zeroed each block by
'clear_output_buses' at the Server level. Same-cycle ordering between
BusOut and BusIn within an instance (a BusIn always sees the live,
accumulated value) is enforced on the Haskell side via E_r edges in
'effectiveDeps'; the runtime simply iterates nodes in the resulting
topological order. Cross-instance and cross-template accumulation
happens because all instances of all templates write to the same
shared pool; the bus contents at any given moment reflect every
BusOut/Out that has run so far in this block (in template-order ×
instance-iteration × per-instance topo-order).

If the input is unconnected or the bus index is invalid, the node
contributes nothing. Multiple writers to the same bus sum.
*/
static void process_out(RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  const auto in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  if (in.empty())
    return;

  const int bus = static_cast<int>(node.controls[0]);
  if (bus < 0 || static_cast<std::size_t>(bus) >= g.server.output_buses.size())
    return;

  // Accumulate into the bus and, in the same pass, track the block's
  // peak |input| for §2.E release-then-free silence detection. The
  // peak is per-instance (not per-node) — multiple Out/BusOut nodes in
  // the same instance contribute to the same max. process_instance
  // resets inst.block_sink_peak to 0 before any node runs this block;
  // process_graph reads it after the instance finishes.
  auto &dst = g.server.output_buses[static_cast<std::size_t>(bus)];
  float peak = inst.block_sink_peak;
  for (int i = 0; i < nframes; ++i) {
    const float s = in[static_cast<std::size_t>(i)];
    dst[static_cast<std::size_t>(i)] += s;
    const float a = std::fabs(s);
    if (a > peak) peak = a;
  }
  inst.block_sink_peak = peak;
}

/* Note [BusIn kernel: read live bus contents]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
BusIn is a source: it copies the current contents of
'g.server.output_buses[bus]' into the node's output port 0, so
downstream consumers can read it like any other audio source.

Same-cycle semantics within an instance: by the time a BusIn runs,
every BusOut/Out on the same bus *within the same instance* has
already accumulated this block's contributions, because the topological
sort on the Haskell side put writers before readers via the E_r edges
derived from BusWrite/BusRead effects. Across instances of the same
template, ordering depends on the iteration order of g.instances.
Across templates, ordering follows g.defs registration order — which
the Haskell side picks to match the topo sort over template
precedence (writers' templates precede readers' templates whenever
a live read intersects a write). For deterministic feedback that
doesn't depend on this ordering, use BusInDelayed instead.

If the bus index is out of range, the kernel emits silence. Reading a
bus that no node wrote in this block is well-defined:
clear_output_buses zeroed the bus at the start of the block, so BusIn
gets zero.
*/
static void process_busin(const RTGraph &g, GraphInstance &inst,
                          std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);

  const int bus = static_cast<int>(node.controls[0]);
  if (bus < 0 || static_cast<std::size_t>(bus) >= g.server.output_buses.size()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  const auto &src = g.server.output_buses[static_cast<std::size_t>(bus)];
  const std::size_t frames = static_cast<std::size_t>(nframes);
  std::copy_n(src.begin(), frames, out.begin());
}

/* Note [BusInDelayed kernel: read previous block's snapshot]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
BusInDelayed is the feedback primitive. It reads from
'g.server.output_buses_prev[bus]' — the frozen snapshot of what the
previous block wrote — rather than from the live
'g.server.output_buses[bus]'. The swap-and-clear in process_graph
guarantees that:

  * output_buses_prev[bus] holds exactly what the previous block's
    BusOut nodes accumulated (or zero if no node wrote that bus,
    or the initial zero state on the very first block);
  * output_buses_prev is *not* mutated during the current block;
  * BusInDelayed therefore returns a stable, deterministic value
    regardless of where it sits in the topological order, which
    instance reads it, or which template it belongs to.

The third point is the design's payoff. On the Haskell side
'BusReadDelayed' is excluded from E_r edges (intra-graph) and from
inter-template precedence (compileTemplateGraph), so a BusInDelayed n
can appear *before* a same-bus BusOut n in any schedule — closing a
feedback loop whose only true cycle is across the block boundary,
where the swap breaks it. With server-global buses, this also closes
*cross-instance* and *cross-template* feedback loops without ordering
hazards.

Out-of-range bus indices emit silence (same as BusIn). Reading a bus
that no node ever wrote — including on the first block, before any
swap — also produces silence, because ensure_output_bus_count
zero-initialises both halves of the pool.

The kernel is a straight memcpy from prev[bus] into the node's output
port; downstream consumers see no difference from BusIn beyond the
one-block latency.

See Note [Bus pool double-buffering].
*/
static void process_busin_delayed(
    const RTGraph &g, GraphInstance &inst,
    std::size_t node_idx, int nframes
) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);

  const int bus = static_cast<int>(node.controls[0]);
  if (bus < 0 || static_cast<std::size_t>(bus) >= g.server.output_buses_prev.size()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  const auto &src = g.server.output_buses_prev[static_cast<std::size_t>(bus)];
  const std::size_t frames = static_cast<std::size_t>(nframes);
  std::copy_n(src.begin(), frames, out.begin());
}

/* Note [Delay processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The Delay kernel wraps q::delay (a fractional ring buffer with
linear interpolation). For each sample it:

  1. Reads delayed = line(signal[i], samples_back), which atomically
     pushes the new sample and returns the value at fractional index
     samples_back into the past.
  2. Writes delayed to the output buffer.

samples_back is computed as 'delay_time_seconds * sample_rate' and
clamped to [0, buffer_size - 1] so an out-of-range request can't
read past the ring. samples_back may be fractional — q::delay's
linear interpolator handles that, which is what makes the kernel
suitable for chorus/flanger/vibrato (audio-rate delay-time
modulation).

When port 1 (delay time) is wired to another node's output, the
kernel is sample-accurate: it reads the modulator per sample and
queries the ring at the per-sample fractional index. When port 1 is
unconnected, the delay time is block-latched from controls[1] —
same pattern as LPF's freq/q.

If the signal input (port 0) is unconnected, output is silence;
nothing is pushed into the ring (so a paused signal source doesn't
"poison" the buffer with stale zeros that later get read out as
bogus delayed taps).

Buffer (re)allocation is gated on (max_time, sample_rate) memos in
DelayState, so the steady-state path does no allocation —
allocation only happens on the very first call and after a sample-
rate change (which is extraordinarily rare).

See Note [Per-node delay state] for the state struct.
*/
static void process_delay(const RTGraph &g, GraphInstance &inst,
                          std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  auto *st = std::get_if<DelayState>(&node.state);
  assert(st && "Delay node has non-Delay state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  // controls[0] = max_time_s, controls[1] = delay_time_s default.
  const double max_time = node.controls[0];

  // (Re)build the ring buffer on first call or after a sample-rate /
  // max-time change. q::delay's constructor sizes the buffer to
  // ceil(max_time * sps) samples and zero-initialises it.
  if (!st->line || st->last_sps != g.sample_rate || st->last_max_time != max_time) {
    st->line.emplace(q::duration{max_time}, g.sample_rate);
    st->last_sps = g.sample_rate;
    st->last_max_time = max_time;
  }

  const auto time_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);
  const float buf_size = static_cast<float>(st->line->size());
  // Reading at sample 0 means "the value just pushed" (no delay).
  // Reading at buf_size - 1 means "the maximum delay this buffer
  // can express." Anything in between is fractional and interpolated.
  const float max_idx = std::max(0.0f, buf_size - 1.0f);

  if (!time_in.empty()) {
    // Sample-accurate delay-time modulation.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      const float t_samples = std::clamp(
        static_cast<float>(time_in[fi]) * g.sample_rate, 0.0f, max_idx);
      out[fi] = (*st->line)(sig_in[fi], t_samples);
    }
  } else {
    // Constant delay time from the control default.
    const float t_samples = std::clamp(
      static_cast<float>(node.controls[1]) * g.sample_rate, 0.0f, max_idx);
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      out[fi] = (*st->line)(sig_in[fi], t_samples);
    }
  }
}

/* Note [Execution order]
~~~~~~~~~~~~~~~~~~~~~~~~~
Inside one instance the runtime processes nodes in storage order.

This is correct because the compiler adds nodes in dense execution
order, which itself comes from the validated topological order
computed on the Haskell side. There is therefore no per-instance
scheduler in this file. The dense node vector is already the
"intra-instance schedule".

Across instances of the same template, the order is the order of
g.instances (vector slot index). Server-global buses (§2.C) make
cross-instance ordering visible: instance A writing bus N before
instance B reading bus N is observable. For deterministic feedback
that doesn't depend on this ordering, use BusInDelayed which reads
from the previous-block snapshot.

Across templates (§2.D.3), the order is g.defs registration order.
The Haskell side (compileTemplateGraph) assigns registration order
to match the topological sort over the inter-template precedence DAG
(T_a precedes T_b iff bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅; BusInDelayed
reads do not contribute, exactly as within a single graph). Cycles
in the precedence DAG are rejected at compile time. The runtime is a
dumb executor — it iterates g.defs in order and never inspects the
precedence relation; the schedule is the compiler's responsibility.

There is no runtime-side knob for reordering. Users who need a
different order edit their bus connectivity (or split into more
templates) and recompile, exactly the way they would edit a node
graph and recompile to change intra-graph order. See "Compile-time
vs runtime ordering" in CLAUDE.md.
*/

static void process_instance(RTGraph &g, GraphInstance &inst, int nframes) noexcept {
  // Look up the spec via inst.template_id. If the template is gone
  // (shouldn't happen — we never shrink g.defs while instances are
  // live — but be defensive), skip the instance.
  const MetaDef *def = template_at(g, inst.template_id);
  if (!def) {
    return;
  }

  // §2.E: zero the per-block sink peak before any kernel runs. Out /
  // BusOut kernels accumulate the block's max |input| into this field;
  // process_graph reads it after this function returns to decide
  // whether a Releasing instance has gone silent.
  inst.block_sink_peak = 0.0f;

  const std::size_t node_count = std::min(def->nodes.size(), inst.nodes.size());
  for (std::size_t i = 0; i < node_count; ++i) {
    switch (def->nodes[i].kind) {
    case NodeKind::SinOsc:
      process_sinosc(g, inst, i, nframes);
      break;
    case NodeKind::Out:
      process_out(g, inst, i, nframes);
      break;
    case NodeKind::Gain:
      process_gain(g, inst, i, nframes);
      break;
    case NodeKind::SawOsc:
      process_sawosc(g, inst, i, nframes);
      break;
    case NodeKind::NoiseGen:
      process_noisegen(g, inst, i, nframes);
      break;
    case NodeKind::LPF:
      process_lpf(g, inst, i, nframes);
      break;
    case NodeKind::Add:
      process_add(g, inst, i, nframes);
      break;
    case NodeKind::Env:
      process_env(g, inst, i, nframes);
      break;
    case NodeKind::BusOut:
      // Out and BusOut share the same bus-write kernel; see
      // Note [Bus-write kernel: Out and BusOut share this].
      process_out(g, inst, i, nframes);
      break;
    case NodeKind::BusIn:
      process_busin(g, inst, i, nframes);
      break;
    case NodeKind::BusInDelayed:
      process_busin_delayed(g, inst, i, nframes);
      break;
    case NodeKind::Delay:
      process_delay(g, inst, i, nframes);
      break;
    default:
      assert(false && "unhandled NodeKind in process_instance");
      break;
    }
  }
}

/* Note [Multi-template execution loop]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
process_graph runs one block of audio. Its job after §2.D.3:

  1. Once per block, swap the bus pool's live and prev vectors and
     zero the new live buffer. This runs at the Server level, before
     any template or instance executes; every instance in this block
     sees the same prev snapshot and writes into the same live pool.

  2. Iterate templates in registration order (== execution order):
     for each template_id in [0, g.defs.size()), find every live
     instance with that template_id and process it.

The outer-by-template, inner-by-instance ordering matters for
cross-template routing. If template T_a writes bus 5 and template
T_b reads bus 5 live, compileTemplateGraph guarantees T_a was
registered before T_b — so all of T_a's instances run (and
accumulate into output_buses[5]) before any of T_b's instances'
BusIn(5) reads.

The current implementation is O(T × I) per block where T = template
count and I = instance count. For typical ensembles (T < 10, I <
1000), the scan cost is negligible compared to per-sample DSP work.
A future optimization would maintain a per-template instance bucket
to make the inner loop O(I_t) instead of O(I), but the speedup is
not measurable today.

Within a template, instances run in slot order (the index in
g.instances). Slot order is implicit in rt_graph_template_instance_add
calls; the runtime does not expose any way to reorder. If a user
needs a specific cross-instance order they can either rely on
template-level precedence (split into multiple templates) or use
BusInDelayed to break the cross-instance dependency.
*/

static void process_graph(RTGraph &g, int nframes) noexcept {
  // Ping-pong the server bus pool, then zero the new live buffer.
  // This runs ONCE per block, before any instance executes — every
  // instance in this block sees the same prev snapshot and writes
  // into the same live buffer. See Note [Bus pool double-buffering].
  std::swap(g.server.output_buses, g.server.output_buses_prev);
  clear_output_buses(g.server, nframes);

  // Iterate templates in registration order. The Haskell side picks
  // registration order to match the topological sort over template
  // precedence, so this loop respects all bus-induced ordering
  // constraints between templates. See Note [Multi-template
  // execution loop].
  const std::size_t template_count = g.defs.size();
  for (std::size_t tid = 0; tid < template_count; ++tid) {
    const int tid_i = static_cast<int>(tid);
    for (auto &maybe_inst : g.instances) {
      if (!maybe_inst) continue;
      if (maybe_inst->template_id != tid_i) continue;
      process_instance(g, *maybe_inst, nframes);

      // §2.E: if the instance is Releasing, drive the silence counter
      // from the peak that process_out just recorded into
      // block_sink_peak. Reclaim the slot once the counter crosses
      // kReleaseSilenceBlocks. Live instances bypass this entirely —
      // the field is consulted only when status == Releasing.
      // See Note [§2.E: release-then-free instance lifecycle].
      if (maybe_inst->status == InstanceStatus::Releasing) {
        if (maybe_inst->block_sink_peak < kReleaseSilenceThreshold) {
          if (++maybe_inst->silent_blocks >= kReleaseSilenceBlocks) {
            maybe_inst.reset();
          }
        } else {
          maybe_inst->silent_blocks = 0;
        }
      }
    }
  }
}

GraphAudioStream::GraphAudioStream(
    RTGraph &graph_, q::audio_device const &device, std::size_t output_channels
)
    : q::audio_stream(
          device, 0, output_channels, device.default_sample_rate(), graph_.max_frames
      ),
      graph(graph_) {}

/* Note [Realtime channel mapping]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The q_io callback receives one non-interleaved output span per hardware
channel.

§2.C: the server bus pool is shared across all instances of all
templates, so the callback can copy each bus directly to the matching
hardware channel without per-instance or per-template summing —
mixing already happened at the bus level when each instance's
BusOut/Out wrote into server.output_buses.

The runtime maps output buses to channels as follows:

  * if the graph has multiple buses, bus N feeds channel N when present
  * if the graph has exactly one bus but the device has multiple output
    channels, bus 0 is duplicated to every channel
*/

void GraphAudioStream::process(out_channels const &out) {
  started.store(true, std::memory_order_release);

  // To be defensive, clamp nframes to max_frames here. (PA spec says the
  // callback can receive different sizes, but we can't handle that.)
  const int nframes = std::min(static_cast<int>(out.frames.size()), graph.max_frames);
  process_graph(graph, nframes);

  for (std::size_t ch = 0; ch < out.size(); ++ch) {
    auto dst = out[ch];
    std::fill(dst.begin(), dst.end(), 0.0f);

    if (graph.server.output_buses.empty()) {
      continue;
    }

    const std::size_t bus =
        (graph.server.output_buses.size() == 1 && out.size() > 1) ? 0 : ch;

    if (bus < graph.server.output_buses.size()) {
      std::copy_n(
          graph.server.output_buses[bus].begin(),
          static_cast<std::size_t>(nframes),
          dst.begin()
      );
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

A separate, non-realtime waiting path polls that flag. This keeps the
callback thread free of locks, I/O, and Haskell RTS interaction.
*/

bool GraphAudioStream::wait_started(std::chrono::milliseconds timeout) noexcept {
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
open_audio_stream(RTGraph &g, int requested_output_channels, int requested_device_id) {
  auto devices = q::audio_device::list();
  if (devices.empty()) {
    return {};
  }

  auto try_make = [&](q::audio_device const &dev) -> std::unique_ptr<GraphAudioStream> {
    if (static_cast<int>(dev.output_channels()) < requested_output_channels) {
      return {};
    }

    auto stream = std::make_unique<GraphAudioStream>(
        g, dev, static_cast<std::size_t>(requested_output_channels)
    );

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

// Build a fresh GraphInstance for the given template, with its own
// per-node state. The bus pool lives on the Server, so a new instance
// carries no bus state of its own. Sets template_id so process_graph
// dispatches to the right MetaDef.
static GraphInstance make_instance(const MetaDef &def, int template_id, int max_frames) {
  GraphInstance inst;
  inst.template_id = template_id;
  inst.nodes.resize(def.nodes.size());
  for (std::size_t i = 0; i < def.nodes.size(); ++i) {
    init_node_state(inst.nodes[i], def.nodes[i], max_frames);
  }
  return inst;
}

// Reset the graph to the initial single-template state: one empty
// MetaDef at index 0, one empty GraphInstance at slot 0 belonging to
// template 0, and an empty Server bus pool. Used by both
// rt_graph_create (initial setup) and rt_graph_clear (graph reload).
//
// The "auto-create template 0 + instance 0" shape is what makes the
// legacy single-template ABI work without explicit
// rt_graph_template_add / rt_graph_template_instance_add calls. New
// callers using the multi-template flow can either:
//   - keep the auto-created template 0 and use it (then add more via
//     rt_graph_template_add for additional templates), or
//   - remove the auto-created instance 0 first via
//     rt_graph_instance_remove and then build up the world they want.
//
// See Note [Legacy single-template ABI as template-0 shim].
static void reset_to_default_state(RTGraph &g) {
  g.sample_rate = kDefaultSampleRate;
  g.defs.clear();
  g.instances.clear();
  g.server.output_buses.clear();
  g.server.output_buses_prev.clear();

  // Push template 0 (empty MetaDef).
  MetaDef def;
  def.max_frames = g.max_frames;
  if (g.capacity > 0) {
    def.nodes.reserve(static_cast<std::size_t>(g.capacity));
  }
  g.defs.push_back(std::move(def));

  // Push instance 0 (empty GraphInstance, template_id = 0).
  GraphInstance inst;
  inst.template_id = 0;
  if (g.capacity > 0) {
    inst.nodes.reserve(static_cast<std::size_t>(g.capacity));
  }
  g.instances.push_back(std::move(inst));
}

/* Note [Legacy single-template ABI as template-0 shim]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Before §2.D.3, the ABI assumed exactly one MetaDef per RTGraph.
After §2.D.3, an RTGraph holds a vector of MetaDefs. To avoid
churning every existing caller (the C++ doctest suite, Haskell's
loadRuntimeGraph, the demos in app/Main.hs), the legacy single-
template entry points are preserved as thin wrappers that target
template 0:

  rt_graph_add_node      -> _template_add_node(g, 0, …)
  rt_graph_set_control   -> _instance_set_control(g, 0, …)   [instance 0]
  rt_graph_connect       -> _template_connect(g, 0, …)
  rt_graph_instance_add  -> _template_instance_add(g, 0)
  rt_graph_read_bus      -> reads server.output_buses directly
  rt_graph_instance_*    -> unchanged signatures, instance_id is
                            globally unique across templates

The auto-created template 0 + instance 0 in rt_graph_create /
rt_graph_clear (see reset_to_default_state) materialises the
"single-template world" so legacy callers don't see any difference.

New multi-template callers register additional templates via
rt_graph_template_add and use the explicit *_template_* /
*_template_instance_* entry points. The two surfaces coexist
unchanged; the legacy surface IS the multi-template surface with
template_id pinned to 0.

This is not a deprecated shim — both surfaces are first-class. The
single-template surface is the natural shape for the typical case
(one synth voice template); the multi-template surface lights up
inter-template ordering and shared bus routing.
*/

} // namespace

// ----------------------------------------------------------------
// C ABI implementation
// ----------------------------------------------------------------

extern "C" {

// Allocate one runtime graph handle. No nodes are configured yet.
//
// Initialises template 0 (an empty MetaDef) and instance 0 (an empty
// GraphInstance belonging to template 0), and starts with an empty
// Server bus pool (grown lazily by add_node and set_control). Legacy
// single-template callers operate transparently on template 0; new
// multi-template callers can either keep template 0 and add more via
// rt_graph_template_add, or remove instance 0 and start fresh.
RTGraph *rt_graph_create(int capacity, int max_frames) {
  auto *g = new RTGraph{};
  g->capacity = std::max(0, capacity);
  g->max_frames = std::max(0, max_frames);
  reset_to_default_state(*g);
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

It stops active audio, resets the sample rate to the default
placeholder value, removes all templates (defs + every instance) and
the server bus pool, and reinstates a fresh template 0 + instance 0
via reset_to_default_state. The graph handle is preserved for reuse.

Multi-template callers: clear before loading a new TemplateGraph, then
use rt_graph_template_add for additional templates and
rt_graph_template_instance_add for explicit voice spawning. The
auto-created instance 0 is yours to reuse, repurpose, or remove.
*/

void rt_graph_clear(RTGraph *g) {
  if (!g) {
    return;
  }

  stop_audio_stream(*g);
  reset_to_default_state(*g);
}

// ----------------------------------------------------------------
// Multi-template C ABI
// ----------------------------------------------------------------

// Add a fresh, empty MetaDef and return its dense template_id.
//
// Registration order is execution order: every template processed
// after this call sits at a higher-numbered template_id and will be
// processed by process_graph after all previously-registered
// templates. The Haskell side (compileTemplateGraph) picks
// registration order to match the topo sort over the inter-template
// precedence DAG, so this single ordering invariant captures both
// the user's intent and the scheduler's guarantee.
int rt_graph_template_add(RTGraph *g) {
  if (!g) return -1;

  MetaDef def;
  def.max_frames = g->max_frames;
  if (g->capacity > 0) {
    def.nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
  g->defs.push_back(std::move(def));
  return static_cast<int>(g->defs.size() - 1);
}

// Number of registered templates. Iterate 0..count-1 to enumerate.
int rt_graph_template_count(RTGraph *g) {
  if (!g) return 0;
  return static_cast<int>(g->defs.size());
}

// Add or reconfigure one node at its dense runtime index in the named
// template.
//
// Updates template_id's spec once and walks every live instance *of
// this template* to install freshly-initialised state at the same
// index. Adding a node "early" (before any extra instances) and
// "late" (after rt_graph_template_instance_add) produce the same
// final layout — every live instance of this template ends up with a
// state slot for the new node. Instances of *other* templates are
// untouched.
void rt_graph_template_add_node(RTGraph *g, int template_id, int node_index, int node_kind) {
  if (!g) return;

  const auto maybe_kind = kind_from_tag(node_kind);
  if (!maybe_kind) {
    std::fprintf(stderr, "Unknown node kind: %d\n", node_kind);
    return;
  }
  const NodeKind kind = *maybe_kind;

  const NodeIndex idx{node_index};
  if (!valid(idx)) {
    return;
  }

  MetaDef *def = template_at(*g, template_id);
  if (!def) {
    return;
  }

  ensure_node_slot(*g, template_id, idx);
  configure_spec(def->nodes[to_size(idx)], kind);
  for (auto &maybe_inst : g->instances) {
    if (!maybe_inst) continue;
    if (maybe_inst->template_id != template_id) continue;
    init_node_state(
        maybe_inst->nodes[to_size(idx)],
        def->nodes[to_size(idx)],
        g->max_frames);
  }

  // Out nodes imply at least one runtime output bus exists, on the
  // shared server pool. Growing here is fine — every other template
  // can read or write the same bus once it's allocated.
  if (kind == NodeKind::Out) {
    ensure_output_bus_count(g->server, 1, g->max_frames);
  }
}

// Set one entry of a template's spec.default_controls. New instances
// of this template (created later via rt_graph_template_instance_add)
// will inherit the value. *Existing* instances are not mutated — use
// rt_graph_instance_set_control to update a specific live instance.
//
// The split exists because user-supplied control defaults belong on
// the spec (so every voice spawned afterward uses them), while live
// per-voice changes belong on the instance (so a voice can be
// modulated independently of its siblings). The legacy
// rt_graph_set_control mutates instance 0 only — it predates the
// spec/instance split and is preserved unchanged.
void rt_graph_template_set_default(
    RTGraph *g, int template_id, int node_index, int control_index, double value
) {
  if (!g) return;

  MetaDef *def = template_at(*g, template_id);
  if (!def) return;

  const NodeIndex ni{node_index};
  const ControlIndex ci{control_index};
  if (!valid(ni) || !valid(ci)) return;

  const std::size_t nidx = to_size(ni);
  if (nidx >= def->nodes.size()) return;

  NodeSpec &spec = def->nodes[nidx];
  const std::size_t cidx = to_size(ci);
  if (cidx >= spec.default_controls.size()) return;

  spec.default_controls[cidx] = value;

  // For Out / BusOut / BusIn / BusInDelayed, control 0 is the bus
  // index. Grow the shared pool here so the kernel never has to.
  const bool kind_uses_bus_slot =
      spec.kind == NodeKind::Out
      || spec.kind == NodeKind::BusOut
      || spec.kind == NodeKind::BusIn
      || spec.kind == NodeKind::BusInDelayed;
  if (kind_uses_bus_slot && cidx == 0 && value >= 0.0) {
    const auto bus = static_cast<std::size_t>(static_cast<int>(value));
    ensure_output_bus_count(g->server, bus + 1, g->max_frames);
  }
}

// Connect one source output port to one destination input port in the
// named template.
//
// Wiring lives on the spec side (NodeSpec::input_refs), so all
// instances of the template share the same connectivity. The Haskell
// side guarantees src and dst both belong to the same template
// (cross-template signal flow goes through the bus pool, not direct
// port wiring); this function does not validate that.
void rt_graph_template_connect(
    RTGraph *g, int template_id,
    int src_index, int src_port, int dst_index, int dst_port
) {
  if (!g) return;

  MetaDef *def = template_at(*g, template_id);
  if (!def) return;

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

  if (sidx >= def->nodes.size() || didx >= def->nodes.size()) {
    return;
  }

  NodeSpec &dst_spec = def->nodes[didx];
  if (dport >= dst_spec.input_refs.size()) {
    return;
  }

  dst_spec.input_refs[dport] = InputRef{src, sp};
}

// Spawn a fresh instance of the named template. Returns globally-
// unique instance_id (>= 0) or -1 on failure.
//
// Slot reuse: scans for the first free std::optional in g.instances
// and overwrites it; only appends if no free slot exists. So an
// instance_id may be returned twice over the life of the RTGraph (the
// dead slot is reused after rt_graph_instance_remove), but never
// concurrently.
int rt_graph_template_instance_add(RTGraph *g, int template_id) {
  if (!g) return -1;

  const MetaDef *def = template_at(*g, template_id);
  if (!def) return -1;

  GraphInstance inst = make_instance(*def, template_id, g->max_frames);

  // Reuse a free slot if any, otherwise append.
  for (std::size_t i = 0; i < g->instances.size(); ++i) {
    if (!g->instances[i].has_value()) {
      g->instances[i] = std::move(inst);
      return static_cast<int>(i);
    }
  }
  g->instances.push_back(std::move(inst));
  return static_cast<int>(g->instances.size() - 1);
}

// ----------------------------------------------------------------
// Legacy single-template ABI (template 0 shim)
// ----------------------------------------------------------------

// Legacy: add a node to template 0. See Note [Legacy single-template
// ABI as template-0 shim].
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind) {
  rt_graph_template_add_node(g, 0, node_index, node_kind);
}

/* Note [Kind-tag introspection]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rt_graph_kind_supported lets the Haskell side machine-check the
agreement between MetaSonic.Types.kindTag and this file's enum
NodeKind / kind_from_tag. The intended caller is a contract test
that enumerates every Haskell NodeKind, computes its kindTag, and
asserts this function returns 1 — catching the silent-drift case
where someone adds a NodeKind in Haskell without updating C++.
*/

int rt_graph_kind_supported(int node_kind) {
  return kind_from_tag(node_kind).has_value() ? 1 : 0;
}

// Legacy: set one control slot on instance 0. Mutates the *instance*,
// not the spec — preserves the pre-§2.D.3 semantics exactly. New
// instances spawned later get spec defaults, not instance 0's values.
// To set spec defaults, use rt_graph_template_set_default.
void rt_graph_set_control(RTGraph *g, int node_index, int control_index, double value) {
  rt_graph_instance_set_control(g, 0, node_index, control_index, value);
}

// Legacy: connect ports in template 0.
void rt_graph_connect(
    RTGraph *g, int src_index, int src_port, int dst_index, int dst_port
) {
  rt_graph_template_connect(g, 0, src_index, src_port, dst_index, dst_port);
}

// Render one block offline; processes every live instance of every
// template, in template registration order.
void rt_graph_process(RTGraph *g, int nframes) {
  if (!g) {
    return;
  }

  if (nframes < 0 || nframes > g->max_frames) {
    std::fprintf(stderr, "Invalid nframes: %d (max_frames=%d)\n", nframes, g->max_frames);
    return;
  }

  // Ensure at least one server bus exists so single-instance default
  // graphs can read bus 0 without explicit setup.
  if (g->server.output_buses.empty()) {
    ensure_output_bus_count(g->server, 1, g->max_frames);
  }

  process_graph(*g, nframes);
}

// Read one bus from the shared server pool. Under §2.C+§2.D.3 the
// bus pool is shared across all instances of all templates, so this
// is a direct pool read with no instance/template scope. Returns
// number of samples written, or 0 on bad arguments.
int rt_graph_read_bus(RTGraph *g, int bus_index, int nframes, float *out) {
  if (!g || !out || bus_index < 0 || nframes <= 0) {
    return 0;
  }

  const std::size_t bus = static_cast<std::size_t>(bus_index);
  if (bus >= g->server.output_buses.size()) {
    return 0;
  }

  const auto &src = g->server.output_buses[bus];
  const std::size_t to_copy =
      std::min(static_cast<std::size_t>(nframes), src.size());
  std::copy_n(src.begin(), to_copy, out);
  return static_cast<int>(to_copy);
}

/* Note [Realtime startup]
~~~~~~~~~~~~~~~~~~~~~~~~~~
rt_graph_start_audio opens and starts the q_io / PortAudio stream.

output_channels controls the hardware channel count requested from the
stream. If the caller passes a non-positive value, the runtime infers a
channel count from the configured server output buses (with a minimum
of one).

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
    output_channels = std::max(1, static_cast<int>(g->server.output_buses.size()));
  }

  if (g->server.output_buses.empty()) {
    ensure_output_bus_count(g->server, 1, g->max_frames);
  }

  auto stream = open_audio_stream(*g, output_channels, device_id);
  if (!stream) {
    std::fprintf(
        stderr,
        "Failed to open audio stream (device_id=%d, outputs=%d)\n",
        device_id,
        output_channels
    );
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

// ----------------------------------------------------------------
// Multi-instance FFI (template-aware variants live above; the
// no-template-id functions here are the legacy "instance of template
// 0" shorthand kept for back-compat with §2.B-era callers)
// ----------------------------------------------------------------

// Legacy: spawn an instance of template 0.
int rt_graph_instance_add(RTGraph *g) {
  return rt_graph_template_instance_add(g, 0);
}

void rt_graph_instance_remove(RTGraph *g, int instance_id) {
  if (!g) return;
  if (instance_id < 0) return;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return;
  g->instances[idx].reset();
}

/* Note [§2.E: release-then-free instance lifecycle]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rt_graph_instance_remove (above) is the hard-free path: the slot is
cleared on the spot, regardless of whether the instance still has
audio in flight. That is the right semantics for panic stops and
voice-stealing under pressure, but it clicks every time a normal
note-off lands on a sustaining voice — the envelope tail and any
ringing delay buffer are cut off at the block boundary.

rt_graph_instance_release is the graceful counterpart. It:

  1. Walks the instance's nodes and, for every Env node, sets the
     gate-default control (controls[0]) to 0.0. The Env kernel
     reads this on its next process call and, on detecting the
     falling edge, invokes q::adsr_envelope_gen::release() to ramp
     down at the configured release rate.

  2. Marks the instance status = Releasing and zeroes silent_blocks.
     The instance keeps being processed every block exactly as before;
     only its lifecycle metadata changes.

  3. process_out (used by both Out and BusOut kernels) records the
     block's peak |input| into inst.block_sink_peak. This is the
     instance's actual contribution to the bus pool — multiple sinks
     in the same instance share the field via a max.

  4. After process_instance returns, process_graph checks: if status
     is Releasing and block_sink_peak < kReleaseSilenceThreshold,
     bump silent_blocks; once it crosses kReleaseSilenceBlocks, the
     slot is reset (instance becomes dead and the id may be reused by
     a future _instance_add). If the instance produces sound again
     (loud transient during release, ringing delay), the counter
     resets and the wait restarts.

Special case — instance has no Env node: there is nothing to "release"
in the audio sense (the envelope is the only mechanism we know how to
gate-off generically), so release == remove. The slot is reset
immediately. Callers that want a graceful tail on an envelope-less
voice should add an Env (gate-driven) to the template.

Edge cases:

  * Releasing an already-Releasing instance is idempotent: the gates
    are already 0, the status flag is already set; only silent_blocks
    is re-zeroed which slightly extends the wait. Harmless.
  * Calling rt_graph_instance_remove on a Releasing instance hard-frees
    immediately — caller asked for it.
  * Calling rt_graph_instance_set_control on a Releasing instance
    works as before; it can re-trigger an envelope by writing 1.0 to
    the gate control. We do *not* automatically transition back to
    Live in that case — the caller has explicitly asked for a release
    and is responsible for any subsequent re-trigger semantics. If
    the gate ramps the envelope back up, block_sink_peak rises above
    threshold and silent_blocks stays at 0, so the instance won't be
    auto-freed for as long as it's audible — but its status remains
    Releasing.

The thresholds are file-scope constants (kReleaseSilenceThreshold,
kReleaseSilenceBlocks). They are not exposed through the C ABI
because the right values depend on hardware noise floor and block
size, neither of which the caller can usefully tune from the host
side. If a future caller needs control, the cleanest extension is a
per-instance override on the GraphInstance, set at release time
(rt_graph_instance_release_with_window or similar).
*/

void rt_graph_instance_release(RTGraph *g, int instance_id) {
  if (!g) return;
  if (instance_id < 0) return;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return;
  if (!g->instances[idx]) return;

  GraphInstance &inst = *g->instances[idx];
  const MetaDef *def = template_at(*g, inst.template_id);
  if (!def) {
    // Defensive: template gone — nothing sensible to do but free.
    g->instances[idx].reset();
    return;
  }

  // Walk the spec, gate-off every Env node by overwriting the
  // instance's control 0 (gate_default). The Env kernel sees the
  // falling edge on its next process call and triggers q's release().
  // Audio inputs (an actual gate signal wired to the Env) override
  // the default at sample 0 of each block, so a gate signal still
  // takes precedence over our override — but that's a misuse case:
  // the caller asked for release on a voice whose gate is being
  // driven externally.
  bool has_env = false;
  const std::size_t node_count = std::min(def->nodes.size(), inst.nodes.size());
  for (std::size_t i = 0; i < node_count; ++i) {
    if (def->nodes[i].kind == NodeKind::Env) {
      has_env = true;
      if (!inst.nodes[i].controls.empty()) {
        inst.nodes[i].controls[0] = 0.0;
      }
    }
  }

  if (!has_env) {
    // Nothing to release — fall back to hard-free. See Note above.
    g->instances[idx].reset();
    return;
  }

  inst.status = InstanceStatus::Releasing;
  inst.silent_blocks = 0;
  // block_sink_peak is reset by process_instance at the top of each
  // block; no need to touch it here.
}

int rt_graph_instance_status(RTGraph *g, int instance_id) {
  if (!g) return -1;
  if (instance_id < 0) return -1;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return -1;
  if (!g->instances[idx]) return -1;
  return static_cast<int>(g->instances[idx]->status);
}

int rt_graph_instance_count(RTGraph *g) {
  if (!g) return 0;
  return static_cast<int>(g->instances.size());
}

int rt_graph_instance_alive(RTGraph *g, int instance_id) {
  if (!g) return 0;
  if (instance_id < 0) return 0;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return 0;
  return g->instances[idx].has_value() ? 1 : 0;
}

void rt_graph_instance_set_control(
    RTGraph *g, int instance_id, int node_index, int control_index, double value
) {
  if (!g) {
    return;
  }

  GraphInstance *inst = instance_at(*g, instance_id);
  if (!inst) {
    return;
  }

  // Spec lookup goes through inst.template_id — each instance carries
  // its own template assignment.
  const MetaDef *def = template_at(*g, inst->template_id);
  if (!def) {
    return;
  }

  const NodeIndex ni{node_index};
  const ControlIndex ci{control_index};
  if (!valid(ni) || !valid(ci)) {
    return;
  }

  const std::size_t nidx = to_size(ni);
  if (nidx >= def->nodes.size() || nidx >= inst->nodes.size()) {
    return;
  }

  // kind comes from the spec; the value we mutate lives on the instance.
  const NodeSpec &spec = def->nodes[nidx];
  NodeInstanceState &node = inst->nodes[nidx];
  const std::size_t cidx = to_size(ci);
  if (cidx >= node.controls.size()) {
    return;
  }

  node.controls[cidx] = value;

  // For Out / BusOut / BusIn / BusInDelayed nodes, control 0 is the
  // bus index. All four reference the shared Server bus pool;
  // growing the pool here ensures the DSP loop never has to. The
  // pool grows once globally even if only one instance touches that
  // bus index — every other instance (across every template) can
  // then read or write the same bus without further setup. See Note
  // [§2.C: server-global buses].
  const bool kind_uses_bus_slot =
      spec.kind == NodeKind::Out
      || spec.kind == NodeKind::BusOut
      || spec.kind == NodeKind::BusIn
      || spec.kind == NodeKind::BusInDelayed;
  if (kind_uses_bus_slot && cidx == 0 && value >= 0.0) {
    const auto bus = static_cast<std::size_t>(static_cast<int>(value));
    ensure_output_bus_count(g->server, bus + 1, g->max_frames);
  }

  if (cidx == 1 && (spec.kind == NodeKind::SinOsc || spec.kind == NodeKind::SawOsc)) {
    set_osc_initial_phase(node, value);
  }
}

// Read one bus from the server pool. The instance_id argument acts as
// a scope check (must reference a live instance) but the data comes
// from the shared pool — under §2.C+§2.D.3, "instance K's view of bus
// N" is just bus N, regardless of which template K belongs to. A dead
// instance returns 0 with the buffer untouched.
int rt_graph_instance_read_bus(
    RTGraph *g, int instance_id, int bus_index, int nframes, float *out
) {
  if (!g || !out || bus_index < 0 || nframes <= 0) {
    return 0;
  }

  if (!instance_at(*g, instance_id)) {
    return 0;
  }

  const std::size_t bus = static_cast<std::size_t>(bus_index);
  if (bus >= g->server.output_buses.size()) {
    return 0;
  }

  const auto &src = g->server.output_buses[bus];
  const std::size_t to_copy =
      std::min(static_cast<std::size_t>(nframes), src.size());
  std::copy_n(src.begin(), to_copy, out);
  return static_cast<int>(to_copy);
}

} // extern "C"
