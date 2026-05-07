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
#include <q/fx/lowpass.hpp>
#include <q/support/duration.hpp>
#include <q/support/phase.hpp>
#include <q/synth/envelope_gen.hpp>
#include <q/synth/noise_gen.hpp>
#include <q/synth/pulse_osc.hpp>
#include <q/synth/saw_osc.hpp>
#include <q/synth/sin_osc.hpp>
#include <q/synth/triangle_osc.hpp>
#include <q_io/audio_device.hpp>
#include <q_io/audio_stream.hpp>

#include <portaudio.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
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

// Lifecycle state of a pool slot. After A.1 the instance pool is a
// std::vector<GraphInstance> of caller-declared size, not a vector of
// std::optional. Slot liveness is now a SlotState enum on the
// GraphInstance itself; the audio thread reads it under acquire
// ordering and processes only Active and Releasing slots.
//
// State transitions:
//
//   Available -- CAS (producer, queued path) -----> Reserved
//   Reserved  -- store (audio drain, Activate) ---> Active
//   Active    -- store (release ABI / drain) -----> Releasing
//   Releasing -- store (audio §2.E silence) ------> Available
//   Active    -- store (remove ABI / drain) ------> Available
//   Available -- store (construction-path spawn) -> Active
//
// The "construction-path" transition (Available → Active in one step,
// without going through Reserved) is reserved for offline /
// stopped-audio callers — rt_graph_template_instance_add and the
// auto-instance-0 setup. The queued realtime path always takes the
// Available → Reserved → Active route because preparation (resize
// nodes, init kernel state, set defaults) must happen *before* the
// audio thread sees the slot, and that work is performed by the
// producer while the slot is Reserved.
//
// ABI mapping for rt_graph_instance_status:
//   Active    -> 0   (caller-visible "Live")
//   Releasing -> 1
//   Available -> -1  (slot is free)
//   Reserved  -> -1  (claimed by producer; not yet visible to other callers)
//
// The integer values for Active and Releasing match the C ABI return
// codes for those states. Available retains -1 (matches the ABI's
// "no such instance" return). Reserved's integer value (2) is
// internal only — _instance_status translates it to -1 because a
// caller that does not own the reservation has no business seeing
// it. Do not renumber Active or Releasing without auditing
// rt_graph_instance_status.
//
// See Note [§2.E: release-then-free instance lifecycle], Note [Pool
// model], and (when it lands) Note [A.2: realtime control queue].
enum class SlotState : int {
  Available = -1,  // free; reusable by any spawn path
  Active    = 0,   // running, gate-on / sustaining (was Live)
  Releasing = 1,   // release requested, awaiting silence
  Reserved  = 2,   // CAS-claimed by producer; preparation in progress, audio thread skips
};

// Wrapper that exposes a SlotState surface but stores the underlying
// value as std::atomic<int>. The int storage avoids portability
// traps around enum atomics (lock-freedom, ABI of <atomic>); callers
// stay in SlotState terms.
//
// Move/copy constructible via *non-atomic* relaxed load/store. This
// is required because std::atomic<T> itself is neither, but
// std::vector<GraphInstance> (the slot pool) needs its element type
// to be moveable for the rare growth path — push_back during
// construction can reallocate the vector and move existing elements.
// The non-atomic move/copy is sound because vector growth is
// single-threaded by contract:
//
//   * during graph construction the audio thread does not exist yet
//     (no rt_graph_start_audio has run), so no other thread observes
//     the slot;
//   * during audio operation the pool size is stable (the realtime
//     queue path never grows the vector — it only flips state on
//     pre-allocated slots), so the move/copy paths never execute.
//
// All real synchronization between producer and audio thread goes
// through load / store / compare_exchange_strong, which use atomic
// operations on the underlying int.
//
// Default memory orders: load is acquire, store is release. CAS
// callers pass success / failure orders explicitly (the canonical
// claim is acquire on success / relaxed on failure for spin-with-
// no-spurious-load-on-failure).
struct AtomicSlotState {
  std::atomic<int> value{static_cast<int>(SlotState::Available)};

  AtomicSlotState() = default;

  // explicit: prevents the implicit-conversion-then-operator=
  // relaxed-store path. Writers must call store() (or
  // compare_exchange_strong) directly, which uses release ordering by
  // default and makes the synchronization point visible at the call
  // site rather than hidden inside an assignment.
  explicit AtomicSlotState(SlotState s) noexcept
      : value(static_cast<int>(s)) {}

  AtomicSlotState(const AtomicSlotState &o) noexcept {
    value.store(static_cast<int>(o.load(std::memory_order_relaxed)),
                std::memory_order_relaxed);
  }

  AtomicSlotState(AtomicSlotState &&o) noexcept {
    value.store(static_cast<int>(o.load(std::memory_order_relaxed)),
                std::memory_order_relaxed);
  }

  AtomicSlotState &operator=(const AtomicSlotState &o) noexcept {
    store(o.load(std::memory_order_relaxed), std::memory_order_relaxed);
    return *this;
  }

  AtomicSlotState &operator=(AtomicSlotState &&o) noexcept {
    store(o.load(std::memory_order_relaxed), std::memory_order_relaxed);
    return *this;
  }

  SlotState load(std::memory_order order = std::memory_order_acquire) const noexcept {
    return static_cast<SlotState>(value.load(order));
  }

  void store(SlotState s, std::memory_order order = std::memory_order_release) noexcept {
    value.store(static_cast<int>(s), order);
  }

  bool compare_exchange_strong(SlotState &expected, SlotState desired,
                                std::memory_order success_order,
                                std::memory_order failure_order) noexcept {
    int expected_int = static_cast<int>(expected);
    const bool ok = value.compare_exchange_strong(
        expected_int, static_cast<int>(desired), success_order, failure_order);
    if (!ok) expected = static_cast<SlotState>(expected_int);
    return ok;
  }
};

// Default per-template polyphony cap when the caller does not call
// rt_graph_template_set_polyphony explicitly. Generous enough for
// every test in tree (the polyphonic stress test uses 8); callers
// that need more declare the cap during construction.
constexpr int kDefaultPolyphony = 8;

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
  kindTag KSmooth       = 14           Smooth       = 14
  kindTag KPulseOsc     = 15           PulseOsc     = 15
  kindTag KTriOsc       = 16           TriOsc       = 16
  kindTag KHPF          = 17           HPF          = 17
  kindTag KBPF          = 18           BPF          = 18
  kindTag KNotch        = 19           Notch        = 19

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
  Smooth       = 14,
  PulseOsc     = 15,
  TriOsc       = 16,
  HPF          = 17,
  BPF          = 18,
  Notch        = 19,
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
  case 14: return NodeKind::Smooth;
  case 15: return NodeKind::PulseOsc;
  case 16: return NodeKind::TriOsc;
  case 17: return NodeKind::HPF;
  case 18: return NodeKind::BPF;
  case 19: return NodeKind::Notch;
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

// Pulse oscillator state. q::pulse_osc carries the bandlimited
// pulse-width as integer phase (`_shift`) so we keep a stateful
// instance and update its width via `osc.width(float)` only when the
// width control changes (or on every sample when an audio-rate width
// modulator is wired). last_width tracks the block-rate path's
// memoization; -1.0 forces reconfigure on the first sample.
struct PulseOscState {
  q::phase_iterator phase_iter;
  q::pulse_osc      osc{0.5f};
  double            last_width = -1.0;
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

// HPF / BPF / Notch share LPF's reconfigure-on-change pattern and only
// differ in the underlying biquad alternative. The audio I/O contract
// is identical (3 inputs [signal, freq, q], 2 controls [freq_default,
// q_default], 1 output). Each carries last_freq / last_q so the
// kernel only re-derives biquad coefficients when a control changes.
struct HPFState {
  q::highpass filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
  double last_freq = -1.0;
  double last_q = -1.0;
};

struct BPFState {
  // bandpass_cpg: constant-peak-gain — peak amplitude stays roughly
  // constant as Q changes, which is the musical / wah-style behaviour.
  // (bandpass_csg, the constant-skirt-gain variant, is sharper but
  // its peak gain scales with Q.)
  q::bandpass_cpg filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
  double last_freq = -1.0;
  double last_q = -1.0;
};

struct NotchState {
  q::notch filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
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

/* Note [Per-node smooth state]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Smooth nodes wrap Q's q::dynamic_smoother (a 2-pole self-modulating
smoother). The smoother is constructed lazily on first process() so
we can hand it the active sample rate (kDefaultSampleRate is a
placeholder until rt_graph_start_audio installs the real one).
last_base_freq / last_sps drive a reconfigure-on-change exactly as
LPF and Env do, so a runtime change to control[0] (the smoother's
base frequency) updates the internal cutoff at the next block
boundary. Initial seeding (low1 = low2 = first input) prevents a
"ramp from zero" attack on the very first block; subsequent blocks
let the smoother track normally.
*/
struct SmoothState {
  std::optional<q::dynamic_smoother> smoother;
  double last_base_freq = -1.0;
  float  last_sps       = -1.0f;
};

// Stateless nodes use monostate: this keeps each runtime node from dealing
// directly with every possible state object.
using NodeState =
    std::variant<std::monostate, OscState, NoiseGenState, LPFState, EnvState,
                 DelayState, SmoothState, PulseOscState,
                 HPFState, BPFState, NotchState>;

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

  // Per-template polyphony cap: the maximum number of simultaneously
  // live (Active or Releasing) instances of this template. Set via
  // rt_graph_template_set_polyphony during construction; defaults to
  // kDefaultPolyphony. rt_graph_template_instance_add returns -1 once
  // the cap is reached (the runtime is dumb about voice stealing —
  // that policy lives in the future Phase-3 voice allocator).
  // See Note [Pool model].
  int polyphony = kDefaultPolyphony;
};

struct GraphInstance {
  // Template this instance was created from. Indexes into
  // RTGraph::defs. Set by make_instance and immutable thereafter.
  int template_id = 0;

  std::vector<NodeInstanceState> nodes;

  // Slot lifecycle state. Atomic so the producer (Phase-3 control
  // queue) and the audio thread can synchronize safely via CAS and
  // acquire / release stores. See AtomicSlotState above for the
  // wrapper, the SlotState comment for the state machine, and
  // Note [§2.E: release-then-free instance lifecycle] / Note [Pool
  // model] for the lifecycle and pool design.
  AtomicSlotState state;

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

  case NodeKind::Smooth:
    // Per-node q::dynamic_smoother. controls[0] is the smoother's
    // base cutoff frequency in Hz (smaller = slower / smoother /
    // laggier); controls[1] is the steady-state target value used
    // when the audio input is unconnected. One audio input
    // (signal_in) and one output. State is allocated lazily on
    // first process() so we can hand it the active sample rate.
    spec.default_controls = {20.0, 0.0};  // [base_freq_hz, target_default]
    spec.input_refs.resize(1);            // [signal_in]
    break;

  case NodeKind::PulseOsc:
    // Bandwidth-limited pulse oscillator. Three audio inputs
    // [freq, phase, width]; three controls [freq_default,
    // phase_default, width_default]. width is in [0, 1] (0.5 =
    // square). Like SinOsc/SawOsc, phase is initial-only — the
    // kernel reads it at the first sample after a reset and then
    // ignores port 1 for the rest of the block.
    spec.default_controls = {0.0, 0.0, 0.5};
    spec.input_refs.resize(3);            // [freq_in, phase_in, width_in]
    break;

  case NodeKind::TriOsc:
    // Bandwidth-limited triangle oscillator. Same shape as
    // SinOsc/SawOsc.
    spec.default_controls.resize(2, 0.0); // [freq, initial_phase]
    spec.input_refs.resize(2);            // [freq_in, phase_in]
    break;

  case NodeKind::HPF:
  case NodeKind::BPF:
  case NodeKind::Notch:
    // Biquad family — same I/O shape as LPF: 3 audio inputs
    // [signal, cutoff, q]; 2 controls [cutoff_default, q_default].
    spec.default_controls = {1000.0, 0.707};
    spec.input_refs.resize(3);            // [signal_in, freq_in, q_in]
    break;
  }
}

// Reset a per-node state slot in place, preserving vector capacities
// across reuse. The first time a slot is initialised for a given kind
// the buffers and controls vector grow to size, allocating; subsequent
// reuses (same shape) reset values without allocating. This is the
// path realtime_reserve hits, so keeping it allocation-free in steady
// state matters for the producer-thread budget.
//
// Capacity preservation rules:
//   * node.outputs: grow with emplace_back when target size exceeds
//     current size (allocates a new inner vector); never shrink, so
//     a slot reused for a smaller-shape kind keeps its old inner
//     buffers around with capacity intact for the next time it goes
//     back to a larger shape.
//   * inner output buffers: assign(n, 0.0f) sets size and zeroes in
//     place; allocates only if current capacity < n.
//   * node.controls: assign(begin, end) preserves capacity for the
//     same reason.
//   * node.state: a single variant assignment per kind. Each state
//     struct's default constructor is non-allocating (lazy-constructed
//     q kernels live behind std::optional).
static void init_node_state(NodeInstanceState &node, const NodeSpec &spec, int max_frames) {
  std::size_t target_outputs = 0;

  switch (spec.kind) {
  case NodeKind::SinOsc:
  case NodeKind::SawOsc:
  case NodeKind::TriOsc:
    target_outputs = 1;
    node.state = OscState{};
    break;

  case NodeKind::NoiseGen:
    target_outputs = 1;
    node.state = NoiseGenState{};
    break;

  case NodeKind::LPF:
    target_outputs = 1;
    node.state = LPFState{};
    break;

  case NodeKind::Env:
    target_outputs = 1;
    node.state = EnvState{};
    break;

  case NodeKind::Delay:
    target_outputs = 1;
    node.state = DelayState{};
    break;

  case NodeKind::Smooth:
    target_outputs = 1;
    node.state = SmoothState{};
    break;

  case NodeKind::PulseOsc:
    target_outputs = 1;
    node.state = PulseOscState{};
    break;

  case NodeKind::HPF:
    target_outputs = 1;
    node.state = HPFState{};
    break;

  case NodeKind::BPF:
    target_outputs = 1;
    node.state = BPFState{};
    break;

  case NodeKind::Notch:
    target_outputs = 1;
    node.state = NotchState{};
    break;

  case NodeKind::Gain:
  case NodeKind::Add:
  case NodeKind::BusIn:
  case NodeKind::BusInDelayed:
    target_outputs = 1;
    node.state = std::monostate{};
    break;

  case NodeKind::Out:
  case NodeKind::BusOut:
    // Sinks: no per-node output buffer. Writes go directly into
    // server.output_buses inside the bus-write kernel.
    target_outputs = 0;
    node.state = std::monostate{};
    break;
  }

  // Grow outputs to hold target_outputs without ever shrinking the
  // outer vector. The grow path allocates one default-constructed
  // inner vector on first use; subsequent reuses for the same kind
  // hit the loop below with size already at target_outputs.
  while (node.outputs.size() < target_outputs) {
    node.outputs.emplace_back();
  }

  // Reset every active output buffer in place. assign(n, v) is
  // allocation-free when the inner capacity already covers n, which
  // is the common case once the slot has been used at least once for
  // this kind.
  const auto frames = static_cast<std::size_t>(max_frames);
  for (std::size_t i = 0; i < target_outputs; ++i) {
    node.outputs[i].assign(frames, 0.0f);
  }

  // Inactive outputs at indices >= target_outputs are kept in the
  // outer vector (capacity preservation for future shape changes
  // back to a higher arity), but each inner buffer is shrunk to
  // size 0 so resolve_input's outputs[port].size() < nframes check
  // returns an empty span. Without this, reconfiguring a node from
  // a higher-arity kind (SinOsc, Add) to a lower-arity kind (Out,
  // BusOut) via rt_graph_template_add_node would leave stale audio
  // at outputs[0..] visible to any downstream wiring still aimed at
  // the old port. clear() preserves capacity.
  for (std::size_t i = target_outputs; i < node.outputs.size(); ++i) {
    node.outputs[i].clear();
  }

  // Per-instance controls take their initial values from the spec's
  // defaults. rt_graph_instance_set_control later writes here,
  // leaving the spec untouched. assign(begin, end) reuses the
  // existing buffer when capacity already covers the new size.
  node.controls.assign(spec.default_controls.begin(), spec.default_controls.end());
}

/* Note [A.2: realtime control queue]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A.1 made the slot pool fixed-shape and the slot state atomic.
A.2 layers a single-producer / single-consumer (SPSC) lock-free
command ring on top so a non-audio "producer" thread (the future
voice allocator, MIDI handler, or any control-plane caller) can
spawn / release / remove / set-control on instances *while the
audio callback is running*, without taking locks and without
allocating on the audio thread.

The four commands the queue ferries today:

  Activate(slot_id)  — publish a producer-prepared slot. The
                       producer has CAS-claimed an Available slot
                       (state == Reserved), populated its template_id
                       and node-state vectors, and written any
                       per-note controls. Activate flips the slot
                       to Active so process_graph's iteration loop
                       starts running its kernels.
  Release(slot_id)   — graceful tear-down. Same body as the direct
                       rt_graph_instance_release.
  Remove(slot_id)    — hard-free. Same body as the direct
                       rt_graph_instance_remove.
  SetControl(slot_id, node_idx, control_idx, value) — write one
                       control value on a live slot. Same body as
                       the direct rt_graph_instance_set_control.

Memory-ordering model
~~~~~~~~~~~~~~~~~~~~~
The producer's release-store on q.write_idx is the *primary*
publication point for everything the audio thread needs to see —
including writes the producer made *before* enqueue:

  Producer (control thread):
    1. CAS state Available → Reserved              (acquire success)
    2. Resize / init inst.nodes; write controls;  (relaxed; no
       set defaults; etc.                          synchronization
                                                   with audio thread
                                                   is needed yet)
    3. Build a ControlCommand for the slot
    4. q.ring[w % cap] = command                  (relaxed)
    5. q.write_idx.store(w + 1, release)          ← publish point

  Consumer (audio thread, top of process_graph):
    A. q.write_idx.load(acquire)  ← synchronizes-with (5)
    B. Read q.ring[r % cap], r++   (now visible: command + steps 1-4)
    C. apply_control_command(...)
    D. q.read_idx.store(r, release) ← backpressure edge

After (A) the audio thread can read everything the producer wrote
before (5), including the command payload and any prep work on the
slot's nodes vector, controls, etc. apply_command(Activate) then
performs a guarded CAS Reserved → Active (release/relaxed) which
publishes the slot's Active state to subsequent process_graph
block iterations via their own state.load(acquire).

In other words: it is the queue's release/acquire pair, not the
later state.store(Active), that publishes producer-prepared slot
contents to the audio thread. The state.store is a separate edge
that exists for the iteration loop to see Active.

The (D) edge is producer/consumer backpressure — the producer's
acquire-load of read_idx in its enqueue path uses (D) to learn
that the audio thread has freed capacity.

Snapshot / batch semantics
~~~~~~~~~~~~~~~~~~~~~~~~~~
The drain snapshots q.write_idx once at the top of process_graph
and drains only commands published *before* that snapshot. This
gives clean block-boundary semantics: commands the producer
enqueues *during* the drain (after the snapshot but before the
next block) are deferred to the next block. The audio thread
never sees a half-written command and never holds the producer
in a tight back-and-forth.

Capacity is fixed at compile time (kControlQueueCapacity = 256)
and chosen as a power of two so wraparound is a cheap mask. With
uint32_t indices and a capacity well below 2^31, the unsigned
wrap arithmetic (w - r) is well-defined even after billions of
commands.

Producer enqueue is bool-returning. On full-queue, the producer
is responsible for handling the failure — typically by rolling
back any reservation it made (CAS Reserved → Available) and
either retrying next block or stealing a voice. Step 3 wires this
into the realtime ABI; today the queue is internal-only and never
populated.

Single-producer contract
~~~~~~~~~~~~~~~~~~~~~~~~
Only one producer thread may enqueue. Phase 3 makes this thread
the voice-allocator's input handler; UI / OSC / MIDI ingress all
feed *into* the allocator rather than the queue directly. If
multiple ingress points ever materialise, an MPSC layer should
sit *above* this queue, not inside it.
*/

constexpr std::size_t kControlQueueCapacity = 256;
static_assert(
    (kControlQueueCapacity & (kControlQueueCapacity - 1)) == 0,
    "kControlQueueCapacity must be a power of two for cheap wraparound"
);

struct ControlCommand {
  enum class Kind : int {
    Activate   = 0,
    Release    = 1,
    Remove     = 2,
    SetControl = 3,
  };
  Kind   kind        = Kind::Activate;
  int    slot_id     = -1;
  // SetControl only — left unused for the other kinds.
  int    node_idx    = 0;
  int    control_idx = 0;
  double value       = 0.0;
};

struct ControlQueue {
  std::array<ControlCommand, kControlQueueCapacity> ring{};
  // SPSC indices. Producer writes write_idx (release); consumer
  // (audio thread) reads write_idx (acquire). Producer reads
  // read_idx (acquire) for backpressure; consumer writes read_idx
  // (release).
  std::atomic<std::uint32_t> write_idx{0};
  std::atomic<std::uint32_t> read_idx{0};
};

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

/* Note [Thread safety contract]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Today (post-§2.E) the C ABI assumes a "single-thread mutator"
contract: while the realtime audio callback is running, the audio
thread is the only thread allowed to touch RTGraph state. Other
threads may construct, configure, mutate, or tear down the graph
only between rt_graph_stop_audio and the next rt_graph_start_audio
(or before any start, or after the final stop).

This is enforced *by convention*, not by locks. Existing callers
obey it by sequencing all graph construction before
rt_graph_start_audio and not modifying state during the realtime
bracket. Tests run offline (no audio thread), so the question does
not arise.

The voice allocator (Phase 3.1) and Q MIDI input (Phase 3.2) will
break the convention: they need to spawn, release, and set-control
on instances while audio is live. A.2 introduces the mechanism
that makes this safe — the realtime-producer entries below mediate
mutation through an SPSC lock-free command queue drained at the
top of every process_graph block. Construction-only and control-
thread entries remain audio-stopped-only; the realtime-producer
entries are the audio-running path.

Per-entry classification — each ABI function falls into exactly
one of these categories:

  Construction-only — mutates shared structure (template specs,
    instance vectors, bus pool sizing) that the audio callback
    iterates. Race-free only when the callback is not running.
      rt_graph_template_add
      rt_graph_template_add_node
      rt_graph_template_set_default
      rt_graph_template_connect
      rt_graph_add_node          (template-0 shim)
      rt_graph_set_control       (template-0 shim — see note below)
      rt_graph_connect           (template-0 shim)

  Control-thread (audio-stopped only) — mutates per-instance
    state and/or the instance vector. Audio thread reads and writes
    the same data structures from the callback. Call only when
    audio is stopped, OR via the realtime-producer entries below
    (which queue the same operations behind the audio thread's
    drain).
      rt_graph_instance_add
      rt_graph_template_instance_add
      rt_graph_instance_remove
      rt_graph_instance_release
      rt_graph_instance_set_control          [+ Reserved exception]
      rt_graph_set_control       (legacy: same posture; see below)

  Note: rt_graph_instance_set_control has one narrow exception to
  the audio-stopped rule — direct write on a Reserved slot is
  permitted *for the producer that owns the reservation*, between
  rt_graph_realtime_reserve and rt_graph_realtime_activate. Reserved
  slots are skipped by process_graph, so the audio thread never
  reads the slot's nodes/controls in that window; the producer's
  writes are published to the audio thread later via the queue's
  release/acquire pair on enqueue/drain of Activate (see Note [A.2:
  realtime control queue]). Outside that window, the
  audio-stopped-only rule applies.

  Realtime-producer (single-producer, audio-running safe) — A.2
    additions. Mediate mutation through the SPSC command queue
    that drain_control_queue applies at the top of every
    process_graph block. Single-producer contract: only ONE thread
    may call this group; UI / OSC / MIDI ingress should feed a
    single producer thread (typically the voice allocator's input
    handler). Concurrent calls from multiple threads will corrupt
    the queue; the C ABI cannot enforce the single-producer rule.
      rt_graph_realtime_reserve
      rt_graph_realtime_cancel
      rt_graph_realtime_activate
      rt_graph_realtime_release
      rt_graph_realtime_remove
      rt_graph_realtime_set_control

  Read-only introspection — reads small scalar or std::optional
    fields. Safe to call concurrently with the callback in the
    sense that it cannot crash, but the value may be stale or torn
    (the callback may flip a slot's optional via the §2.E auto-free
    path). Do not use for synchronization.
      rt_graph_kind_supported   (pure function — always safe)
      rt_graph_template_count
      rt_graph_instance_count
      rt_graph_instance_alive
      rt_graph_instance_status

  Bus read — copies samples out of server.output_buses. The audio
    callback writes to those vectors during process_graph. Bus pool
    *resizing* is construction-only (see above), so there is no
    container resize race; only sample contents may be torn. Useful
    for tests and offline rendering; not for sample-accurate
    sampling alongside live audio.
      rt_graph_read_bus

  Audio lifecycle — open and close the realtime stream. Each is
    expected to be called once per session and never concurrently
    with itself or with the other.
      rt_graph_start_audio
      rt_graph_stop_audio
      rt_graph_wait_started   (polls an std::atomic<bool>; safe)

  Render — runs process_graph for one block.
      rt_graph_process — single-thread only. While audio is running
        the callback runs process_graph from its own thread; a
        concurrent call from any other thread is UB. Used by
        offline tests and the demo's pre-audio warm-up.

  Allocation / reset — cooperate with the audio lifecycle.
      rt_graph_create — no concurrency by construction (caller does
        not yet hold the handle).
      rt_graph_destroy — calls stop_audio_stream first, joining the
        audio thread before deleting the RTGraph. Caller must ensure
        no other thread holds the handle.
      rt_graph_clear — same: joins the audio thread, then resets
        state in the now-quiescent graph.

The §2.E auto-free path (process_graph reclaiming a Releasing slot
that has gone silent for kReleaseSilenceBlocks) runs entirely on
the audio thread and mutates only the slot's std::optional. Other
threads that have a stored instance_id from before may observe the
liveness change via instance_alive / instance_status; they must not
assume a previously-live id stays live across blocks. This is the
same observable model the voice allocator will need to handle when
voices auto-free between note-on and note-off.
*/

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
  // Pool of GraphInstance slots. Replaces the pre-A.1
  // std::vector<std::optional<GraphInstance>>: each slot is now a
  // GraphInstance carrying a SlotState; "dead" is state == Available
  // (the slot exists in the vector but has no live instance), so
  // freeing an instance no longer destructs anything — vector
  // capacity for the per-node state is preserved across reuse.
  // See Note [Pool model].
  std::vector<GraphInstance> instances;
  Server server;
  std::unique_ptr<GraphAudioStream> audio;

  // A.2: lock-free SPSC command queue for realtime mutation. Filled
  // by the producer thread's realtime APIs (step 3); drained by the
  // audio thread at the very top of process_graph (before bus swap
  // or any kernel runs). See Note [A.2: realtime control queue].
  ControlQueue control_queue;
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
// / dead-slot ids. After A.1 a "dead slot" is one whose SlotState is
// Available; the GraphInstance object still exists in the vector and
// retains its node-state allocations for the next reuse, but it is
// not part of the audio schedule.
[[nodiscard]] static GraphInstance *
instance_at(RTGraph &g, int instance_id) noexcept {
  if (instance_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g.instances.size()) return nullptr;
  if (g.instances[idx].state.load() == SlotState::Available) return nullptr;
  return &g.instances[idx];
}

[[nodiscard]] static const GraphInstance *
instance_at(const RTGraph &g, int instance_id) noexcept {
  if (instance_id < 0) return nullptr;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g.instances.size()) return nullptr;
  if (g.instances[idx].state.load() == SlotState::Available) return nullptr;
  return &g.instances[idx];
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
  for (auto &inst : g.instances) {
    // ensure_node_slot is [T:construction] and shouldn't see any
    // Reserved slots in practice (no producer is running during
    // construction), but skip them defensively if encountered: a
    // Reserved slot is being prepared by a producer that owns
    // inst.nodes; growing the vector behind the producer's back
    // would race their writes.
    const SlotState s = inst.state.load();
    if (s != SlotState::Active && s != SlotState::Releasing) continue;
    if (inst.template_id != template_id) continue;
    if (inst.nodes.size() <= idx) {
      inst.nodes.resize(idx + 1);
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
  // Multiple oscillator state types share a phase_iterator (OscState
  // for SinOsc/SawOsc, PulseOscState for PulseOsc, ...). Locate the
  // right one by variant alternative; if none matches, the caller
  // dispatched a phase-set on a non-oscillator kind.
  q::phase_iterator *iter = nullptr;
  if (auto *osc = std::get_if<OscState>(&node.state)) {
    iter = &osc->phase_iter;
  } else if (auto *p = std::get_if<PulseOscState>(&node.state)) {
    iter = &p->phase_iter;
  }
  assert(iter && "oscillator node has non-oscillator state");
  if (!iter) {
    return;
  }

  const double frac = std::isfinite(value) ? value - std::floor(value) : 0.0;

  // Note [Phase setting semantics]
  // q::phase_iterator has no public API for setting _phase independently of _step.
  // phase_iterator::set(freq, sps) updates only _step.
  // operator=(phase) also sets _step, not _phase — a counterintuitive trap.
  //
  // Let's keep this direct field access here so a Q API change breaks in one place...
  iter->_phase = q::frac_to_phase(frac);
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

/* Note [PulseOsc processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Bandwidth-limited pulse oscillator wrapping q::pulse_osc. Three audio
inputs in declared order: freq (port 0), phase (port 1, initial-only,
ignored after the first sample like SinOsc/SawOsc), and width (port 2,
in [0, 1]; 0.5 = square wave). When width is wired the kernel takes a
sample-accurate path (per-sample osc.width(...) call); otherwise it
memo-checks controls[2] against last_width and updates only on change.

Width semantics: q's pulse_osc holds the pulse threshold internally
as integer phase. We update via osc.width(float) which stores the
converted phase in osc._shift. The bandlimit (poly_blep) correctly
follows the new shift on the next sample, so width modulation is
glitch-free as long as the modulator stays within [0, 1].
*/

// Sanitize a width sample before handing it to q::pulse_osc::width().
// q::frac_to_phase asserts (debug) on negative input, and on
// non-finite input would multiply by NaN/Inf and convert the result
// to uint32_t — undefined per the C++ standard. Clamp finite values
// to [0, 1] and substitute the kindSpec default (0.5 = square) for
// NaN / +/-Inf. Width 1.0 is handled internally by frac_to_phase
// (returns phase::end), so [0, 1] is the safe domain.
static inline float sanitize_pulse_width(float w) noexcept {
  return std::isfinite(w) ? std::clamp(w, 0.0f, 1.0f) : 0.5f;
}

static void process_pulse_osc(const RTGraph &g, GraphInstance &inst,
                              std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in  = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  const auto width_in = resolve_input(g, inst, node_idx, PortIndex{2}, nframes);

  auto *st = std::get_if<PulseOscState>(&node.state);
  assert(st && "PulseOsc node has non-pulse state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  // Width: sample-accurate modulation when port 2 is wired; otherwise
  // memoize against last_width and update once per block on change.
  // Block-rate path: sanitize the *raw* control value before
  // comparing against last_width so a single non-finite write
  // doesn't lock the memo into a poison state.
  if (width_in.empty()) {
    const float w = sanitize_pulse_width(static_cast<float>(node.controls[2]));
    if (w != st->last_width) {
      st->osc.width(w);
      st->last_width = w;
    }
  }

  if (!freq_in.empty()) {
    // Sample-accurate FM (and PWM, if width_in is also wired).
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      st->phase_iter.set(
          q::frequency{static_cast<double>(freq_in[fi])}, g.sample_rate);
      if (!width_in.empty()) {
        st->osc.width(sanitize_pulse_width(width_in[fi]));
      }
      out[fi] = st->osc(st->phase_iter++);
    }
  } else {
    // Constant frequency: set the increment once per block. Width
    // may still be sample-accurate.
    const double freq = node.controls[0];
    st->phase_iter.set(q::frequency{freq}, g.sample_rate);
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      if (!width_in.empty()) {
        st->osc.width(sanitize_pulse_width(width_in[fi]));
      }
      out[fi] = st->osc(st->phase_iter++);
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

/* Note [HPF / BPF / Notch processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

These three are biquad siblings of LPF: same I/O contract (3 audio
inputs [signal, freq, q], 2 controls [freq_default, q_default]),
same block-latched freq/q (read at sample 0 each block), same
reconfigure-on-change discipline. They differ only in the underlying
q::biquad alternative:

  * HPF   uses q::highpass.
  * BPF   uses q::bandpass_cpg (constant-peak-gain — peak amplitude
          is roughly Q-independent, the musical / wah variant).
  * Notch uses q::notch (band-reject).

Cutoff and q are block-rate, not sample-accurate: the kernel samples
freq_in[0] / q_in[0] once per block. An upstream Smooth softens
block-to-block jumps in the cutoff trajectory (a CC value that
updates once per block, for example) but is itself only observed at
sample 0 of each block, so it doesn't give within-block sweeps. True
sample-accurate filter FM would need a per-sample biquad reconfigure
loop here, which doesn't exist today.
*/

static void process_hpf(const RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);
  const auto q_in    = resolve_input(g, inst, node_idx, PortIndex{2}, nframes);
  const double freq  = !freq_in.empty() ? static_cast<double>(freq_in[0]) : node.controls[0];
  const double q_val = !q_in.empty()    ? static_cast<double>(q_in[0])    : node.controls[1];

  auto *st = std::get_if<HPFState>(&node.state);
  assert(st && "HPF node has non-HPF state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  if (freq != st->last_freq || q_val != st->last_q) {
    st->filter.config(q::frequency{freq}, g.sample_rate, q_val);
    st->last_freq = freq;
    st->last_q    = q_val;
  }
  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = st->filter(sig_in[fi]);
  }
}

static void process_bpf(const RTGraph &g, GraphInstance &inst,
                        std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);
  const auto q_in    = resolve_input(g, inst, node_idx, PortIndex{2}, nframes);
  const double freq  = !freq_in.empty() ? static_cast<double>(freq_in[0]) : node.controls[0];
  const double q_val = !q_in.empty()    ? static_cast<double>(q_in[0])    : node.controls[1];

  auto *st = std::get_if<BPFState>(&node.state);
  assert(st && "BPF node has non-BPF state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  if (freq != st->last_freq || q_val != st->last_q) {
    st->filter.config(q::frequency{freq}, g.sample_rate, q_val);
    st->last_freq = freq;
    st->last_q    = q_val;
  }
  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = st->filter(sig_in[fi]);
  }
}

static void process_notch(const RTGraph &g, GraphInstance &inst,
                          std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);
  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{1}, nframes);
  const auto q_in    = resolve_input(g, inst, node_idx, PortIndex{2}, nframes);
  const double freq  = !freq_in.empty() ? static_cast<double>(freq_in[0]) : node.controls[0];
  const double q_val = !q_in.empty()    ? static_cast<double>(q_in[0])    : node.controls[1];

  auto *st = std::get_if<NotchState>(&node.state);
  assert(st && "Notch node has non-Notch state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }
  if (freq != st->last_freq || q_val != st->last_q) {
    st->filter.config(q::frequency{freq}, g.sample_rate, q_val);
    st->last_freq = freq;
    st->last_q    = q_val;
  }
  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = st->filter(sig_in[fi]);
  }
}

/* Note [TriOsc processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Same shape as SinOsc/SawOsc: q::phase_iterator + a stateless
waveshape. q::triangle is a free constant of triangle_osc. Phase
port (port 1) is initial-only, same convention as SinOsc/SawOsc.
*/

static void process_triosc(const RTGraph &g, GraphInstance &inst,
                           std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  auto *osc = std::get_if<OscState>(&node.state);
  assert(osc && "TriOsc node has non-oscillator state");
  if (!osc) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  if (!freq_in.empty()) {
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      osc->phase_iter.set(
          q::frequency{static_cast<double>(freq_in[fi])}, g.sample_rate);
      out[fi] = q::triangle(osc->phase_iter++);
    }
  } else {
    const double freq = node.controls[0];
    osc->phase_iter.set(q::frequency{freq}, g.sample_rate);
    for (int i = 0; i < nframes; ++i) {
      out[static_cast<std::size_t>(i)] = q::triangle(osc->phase_iter++);
    }
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

/* Note [Smooth processing semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Smooth wraps q::dynamic_smoother and runs it sample-by-sample over
its audio input. When the input is unconnected, controls[1] is
read as a block-rate constant target — that is the typical
Phase 3.3c use case: a Param connected through a Smooth, with
the producer thread updating the Param via the realtime ABI when
CC or pitch-bend events arrive. Block-rate jumps in the target
become continuous ramps in the smoother's output, which the
downstream consumer reads at audio rate.

Reconfigure-on-change discipline: changes to controls[0] (base
frequency) update the smoother's internal cutoff at the next block
boundary (same idiom as LPF and Env). The smoother is constructed
lazily on first process so we have the active sample rate; on
construction the internal IIR state is seeded to the first input
sample, avoiding a "ramp from zero" attack on the first block.

Stateful (the IIR carries low1/low2 history across blocks). The
state is per-instance with no shared resource, so Eff is Pure and
rate is SampleRate. See Note [Per-node smooth state].
*/
static void process_smooth(const RTGraph &g, GraphInstance &inst,
                           std::size_t node_idx, int nframes) noexcept {
  auto &node = inst.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g, inst, node_idx, PortIndex{0}, nframes);

  auto *st = std::get_if<SmoothState>(&node.state);
  assert(st && "Smooth node has non-Smooth state");
  if (!st) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  // q::dynamic_smoother computes its IIR coefficients as
  // wc = base_hz / sps; gc = tan(pi * wc); g0 = 2*gc / (1 + gc).
  // The math falls apart at three input ranges:
  //   - NaN / non-finite: tan propagates NaN through the IIR state
  //     and the smoother is permanently poisoned.
  //   - base_hz <= 0: g0 <= 0, which either freezes the smoother at
  //     its seed (g0 == 0) or drives low1 *away* from the input
  //     (g0 < 0).
  //   - base_hz >= sample_rate / 2: wc >= 0.5, where tan(pi*wc) goes
  //     to +inf and then wraps negative — same instability as the
  //     <= 0 case, by a different route.
  // Sanitize to [kMin, 0.49 * sps]. The spec defaults are already
  // guarded (kindSpec sets 20 Hz), but per-instance set_control can
  // land any double here at runtime.
  constexpr double kMinBaseFreqHz = 0.001;
  const double raw_base = node.controls[0];
  const double max_base = 0.49 * static_cast<double>(g.sample_rate);
  const double base_hz =
      std::isfinite(raw_base)
          ? std::clamp(raw_base, kMinBaseFreqHz, max_base)
          : kMinBaseFreqHz;
  const float  target  = static_cast<float>(node.controls[1]);

  // Lazy construction on first call or after a sample-rate change.
  // Seed the IIR state to the first input sample so the smoother
  // starts at steady state instead of ramping from zero.
  if (!st->smoother || st->last_sps != g.sample_rate) {
    st->smoother.emplace(q::frequency{base_hz}, g.sample_rate);
    const float seed = sig_in.empty() ? target : sig_in[0];
    *st->smoother    = seed;
    st->last_sps       = g.sample_rate;
    st->last_base_freq = base_hz;
  } else if (base_hz != st->last_base_freq) {
    st->smoother->base_frequency(q::frequency{base_hz}, g.sample_rate);
    st->last_base_freq = base_hz;
  }

  if (!sig_in.empty()) {
    // Sample-accurate input.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      out[fi] = (*st->smoother)(sig_in[fi]);
    }
  } else {
    // Block-rate target from controls[1]; the producer updates this
    // between blocks via the realtime ABI.
    for (int i = 0; i < nframes; ++i) {
      const std::size_t fi = static_cast<std::size_t>(i);
      out[fi] = (*st->smoother)(target);
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

// ----------------------------------------------------------------
// Lifecycle helpers (shared between the direct ABI entries and the
// queued-drain path)
// ----------------------------------------------------------------

// Apply the gate-off + state-flip half of the §2.E release protocol.
// Caller is responsible for the pre-state gate:
//   * direct ABI (rt_graph_instance_release): caller gates to
//     Active or Releasing (Reserved is producer-private; Available
//     is no-op).
//   * queued drain (apply_control_command Release): caller gates to
//     Active only — Releasing is already in flight, Reserved means
//     the producer enqueued Release before Activate (a producer bug
//     we silently no-op).
//
// Mutations performed:
//   * walk every Env node in the slot, write controls[0] = 0.0 so
//     the kernel sees the falling edge on its next process call;
//   * if no Env was found, hard-free (state.store(Available));
//   * else flip to Releasing and reset silent_blocks.
//
// No allocation. Safe to call from the audio thread.
static void apply_instance_release(
    RTGraph &g, GraphInstance &inst
) noexcept {
  const MetaDef *def = template_at(g, inst.template_id);
  if (!def) {
    // Defensive: template gone — nothing sensible to do but free.
    inst.state.store(SlotState::Available);
    return;
  }

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
    // Nothing to release — fall back to hard-free. See Note
    // [§2.E: release-then-free instance lifecycle].
    inst.state.store(SlotState::Available);
    return;
  }

  inst.state.store(SlotState::Releasing);
  inst.silent_blocks = 0;
  // block_sink_peak is reset by process_instance at the top of each
  // block; no need to touch it here.
}

// Apply one control write to a live slot. Bounds-checks the node /
// control indices against the slot's spec and does the SinOsc/SawOsc
// initial-phase special case. Caller is responsible for the pre-
// state gate (Active or Releasing for the direct ABI; Active or
// Releasing for the drain — Reserved slots receive their controls
// from the producer's pre-enqueue path, not from the queue).
//
// No allocation. Safe to call from the audio thread.
static void apply_instance_set_control(
    RTGraph &g, GraphInstance &inst,
    int node_index, int control_index, double value
) noexcept {
  const MetaDef *def = template_at(g, inst.template_id);
  if (!def) return;

  const NodeIndex ni{node_index};
  const ControlIndex ci{control_index};
  if (!valid(ni) || !valid(ci)) return;

  const std::size_t nidx = to_size(ni);
  if (nidx >= def->nodes.size() || nidx >= inst.nodes.size()) return;

  const NodeSpec &spec = def->nodes[nidx];
  NodeInstanceState &node = inst.nodes[nidx];
  const std::size_t cidx = to_size(ci);
  if (cidx >= node.controls.size()) return;

  node.controls[cidx] = value;

  if (cidx == 1 && (spec.kind == NodeKind::SinOsc
                    || spec.kind == NodeKind::SawOsc
                    || spec.kind == NodeKind::PulseOsc
                    || spec.kind == NodeKind::TriOsc)) {
    set_osc_initial_phase(node, value);
  }
}

// Prepare a freshly-CAS-Reserved slot for a given template. Sets
// template_id, resizes the per-node state vector to match the
// template's spec, and re-initialises every node's kernel state via
// init_node_state. The slot's SlotState stays at Reserved — only
// rt_graph_realtime_activate (via the queued drain) flips it to
// Active. After this call the producer may apply per-note overrides
// directly with rt_graph_instance_set_control on the Reserved slot;
// see the [T:control] exception in rt_graph.h.
//
// Allocation policy: the first time a slot is prepared for a given
// template shape, three things may allocate: slot.nodes.resize grows
// the outer vector, init_node_state grows each node's outputs vector
// and inner buffers, and node.controls is sized to spec. Once the
// slot has been used at least once for that shape, every subsequent
// reserve hits the in-place reset paths in init_node_state and is
// allocation-free. The recommended pre-warm pattern (spawn N
// instances via _template_instance_add then immediately remove
// them) drives every slot through that first-use path during
// construction, so producer-thread reserves under steady state
// don't allocate.
//
// Not noexcept: the first-use allocations can still throw
// bad_alloc. rt_graph_realtime_reserve wraps the call in a try/catch
// that rolls the slot back to Available so no exception escapes
// through the extern "C" boundary. See Note [Pool model] and Note
// [A.2: realtime control queue].
static void prepare_reserved_slot(
    RTGraph &g, GraphInstance &slot, const MetaDef &def, int template_id
) {
  slot.template_id    = template_id;
  slot.silent_blocks  = 0;
  slot.block_sink_peak = 0.0f;
  slot.nodes.resize(def.nodes.size());
  for (std::size_t i = 0; i < def.nodes.size(); ++i) {
    init_node_state(slot.nodes[i], def.nodes[i], g.max_frames);
  }
}

// Producer-side enqueue. Returns true if the command was published,
// false if the queue is full (caller is responsible for handling
// the failure — typically by rolling back any reservation). The
// release-store on write_idx is THE publication point for both the
// command payload and any prior producer prep work; see Note [A.2:
// realtime control queue].
static bool enqueue_command(ControlQueue &q, const ControlCommand &cmd) noexcept {
  // Producer-only access on write_idx — relaxed load is enough.
  const std::uint32_t w = q.write_idx.load(std::memory_order_relaxed);
  // Acquire on read_idx synchronizes-with the audio thread's
  // release-store at the bottom of drain_control_queue, so we see
  // freed slots once the audio thread has consumed them.
  const std::uint32_t r = q.read_idx.load(std::memory_order_acquire);
  if (w - r >= kControlQueueCapacity) return false;
  q.ring[w % kControlQueueCapacity] = cmd;
  // Release publish. After this store, the audio drain's acquire-
  // load on write_idx will see ring[w%cap] AND every write the
  // producer made before this point (including the slot's
  // template_id, nodes, controls, etc. for an Activate).
  q.write_idx.store(w + 1, std::memory_order_release);
  return true;
}

// ----------------------------------------------------------------
// A.2: realtime control queue — apply + drain
// ----------------------------------------------------------------
//
// See Note [A.2: realtime control queue] for the design and memory-
// ordering model. apply_control_command is invoked by the audio
// thread (drain) for each command it consumes from the SPSC ring.
// Every command kind is guarded by the slot's expected pre-state;
// a mismatched state is silently dropped. No allocation; safe on
// the audio path.

static void apply_control_command(RTGraph &g, const ControlCommand &cmd) noexcept {
  if (cmd.slot_id < 0) return;
  const std::size_t idx = static_cast<std::size_t>(cmd.slot_id);
  if (idx >= g.instances.size()) return;
  GraphInstance &inst = g.instances[idx];

  switch (cmd.kind) {
    case ControlCommand::Kind::Activate: {
      // Guarded Reserved → Active. CAS so we don't blindly publish
      // a slot whose state isn't what the producer thought it was
      // (caller bug, external race, or producer cancellation
      // between enqueue and drain). The release-success ordering
      // makes the slot's prepared contents visible to subsequent
      // process_graph block iterations via their state.load(acquire).
      // (The queue's own release/acquire pair already published the
      // contents to *this* drain — see Note [A.2: realtime control
      // queue].)
      SlotState expected = SlotState::Reserved;
      (void) inst.state.compare_exchange_strong(
          expected, SlotState::Active,
          std::memory_order_release,
          std::memory_order_relaxed);
      break;
    }
    case ControlCommand::Kind::Release: {
      // Drain-path Release acts only on Active. Reserved is the
      // producer's private state; Releasing is already in flight;
      // Available is a no-op.
      const SlotState s = inst.state.load();
      if (s != SlotState::Active) break;
      apply_instance_release(g, inst);
      break;
    }
    case ControlCommand::Kind::Remove: {
      // Drain-path Remove acts on Active or Releasing. Hard-free
      // a Reserved slot would yank the producer's claim; refuse.
      const SlotState s = inst.state.load();
      if (s != SlotState::Active && s != SlotState::Releasing) break;
      inst.state.store(SlotState::Available);
      break;
    }
    case ControlCommand::Kind::SetControl: {
      // Drain-path SetControl acts only on slots already in the
      // audio schedule (Active or Releasing). Reserved slots
      // receive their initial controls from the producer's pre-
      // enqueue path (direct write to the producer-owned slot),
      // not from the queue. Available is a no-op.
      const SlotState s = inst.state.load();
      if (s != SlotState::Active && s != SlotState::Releasing) break;
      apply_instance_set_control(g, inst, cmd.node_idx, cmd.control_idx, cmd.value);
      break;
    }
  }
}

// Drain everything the producer has published up to the snapshot
// taken at the head of this call. Commands enqueued *during* the
// drain (after the snapshot) are deferred to the next block — that
// is the block-boundary semantic the user-facing contract advertises.
static void drain_control_queue(RTGraph &g) noexcept {
  ControlQueue &q = g.control_queue;

  // Acquire the producer's publish-up-to point. This is THE point
  // that publishes both the command payload AND any prior producer
  // prep (slot Reserved + nodes preparation) to the audio thread —
  // synchronizes-with the producer's release-store on write_idx.
  const std::uint32_t end_w = q.write_idx.load(std::memory_order_acquire);
  std::uint32_t r = q.read_idx.load(std::memory_order_relaxed);

  // Unsigned wrap arithmetic: end_w - r is the count of unconsumed
  // commands modulo 2^32. With kControlQueueCapacity ≪ 2^31 and a
  // bool-returning enqueue that refuses to overflow, this stays
  // correct for the lifetime of the graph.
  while (r != end_w) {
    apply_control_command(g, q.ring[r % kControlQueueCapacity]);
    ++r;
  }

  // Backpressure edge: republishing the new read_idx lets the
  // producer's acquire-load on read_idx see the freed capacity in
  // its enqueue path. Not part of the command-publication chain
  // (that's the write_idx pair above).
  q.read_idx.store(r, std::memory_order_release);
}

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
    case NodeKind::Smooth:
      process_smooth(g, inst, i, nframes);
      break;
    case NodeKind::PulseOsc:
      process_pulse_osc(g, inst, i, nframes);
      break;
    case NodeKind::TriOsc:
      process_triosc(g, inst, i, nframes);
      break;
    case NodeKind::HPF:
      process_hpf(g, inst, i, nframes);
      break;
    case NodeKind::BPF:
      process_bpf(g, inst, i, nframes);
      break;
    case NodeKind::Notch:
      process_notch(g, inst, i, nframes);
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
  // Drain the realtime control queue *before* anything else runs.
  // This snapshots the producer's published-up-to point once and
  // applies every command published before the snapshot, so any
  // Activate / Release / Remove / SetControl that arrived between
  // the previous block and now takes effect during this block. The
  // queue's acquire-load on write_idx publishes both the command
  // payload and any prior producer prep work (Reserved-slot
  // node-state preparation) to this thread. See Note [A.2: realtime
  // control queue].
  drain_control_queue(g);

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
    for (auto &inst : g.instances) {
      // Skip every state that is not part of the audio schedule.
      // Available is "free", Reserved is the producer's private claim
      // (preparation in progress — the producer may be resizing /
      // initialising inst.nodes right now, so the audio thread MUST
      // NOT race those writes). Only Active and Releasing slots have
      // already been published into the schedule. Snapshot once; the
      // §2.E silence-window branch reuses the snapshot.
      const SlotState s = inst.state.load();
      if (s != SlotState::Active && s != SlotState::Releasing) continue;
      if (inst.template_id != tid_i) continue;
      process_instance(g, inst, nframes);

      // §2.E: if the slot is Releasing, drive the silence counter from
      // the peak that process_out just recorded into block_sink_peak.
      // Once the counter crosses kReleaseSilenceBlocks, transition the
      // slot back to Available — the GraphInstance object stays in
      // place (its node-state vectors are kept for the next reuse), so
      // there is no allocation/deallocation on the audio thread. Active
      // slots bypass this entirely; the field is consulted only when
      // state == Releasing. See Note [§2.E: release-then-free instance
      // lifecycle].
      if (s == SlotState::Releasing) {
        if (inst.block_sink_peak < kReleaseSilenceThreshold) {
          if (++inst.silent_blocks >= kReleaseSilenceBlocks) {
            inst.state.store(SlotState::Available);
          }
        } else {
          inst.silent_blocks = 0;
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

  // Discard any control commands that were enqueued before the
  // reload. Without this, drain_control_queue would replay stale
  // commands against the freshly-rebuilt template / instance pool
  // on the next process call. rt_graph_clear stops audio first, so
  // there is no concurrent producer or consumer here — relaxed is
  // sufficient. The ring contents need not be zeroed: enqueue
  // overwrites each slot before the next drain reads it.
  g.control_queue.write_idx.store(0, std::memory_order_relaxed);
  g.control_queue.read_idx.store(0, std::memory_order_relaxed);

  // Push template 0 (empty MetaDef).
  MetaDef def;
  def.max_frames = g.max_frames;
  if (g.capacity > 0) {
    def.nodes.reserve(static_cast<std::size_t>(g.capacity));
  }
  g.defs.push_back(std::move(def));

  // Push instance 0 (empty GraphInstance, template_id = 0). Active
  // by default so the legacy single-template ABI (rt_graph_set_control
  // and friends, which target instance 0) sees a live slot from the
  // moment the handle is constructed.
  GraphInstance inst;
  inst.template_id = 0;
  inst.state.store(SlotState::Active);
  if (g.capacity > 0) {
    inst.nodes.reserve(static_cast<std::size_t>(g.capacity));
  }
  g.instances.push_back(std::move(inst));
}

/* Note [Pool model]
~~~~~~~~~~~~~~~~~~~~~
A.1 replaces the pre-existing instance representation
(std::vector<std::optional<GraphInstance>>, with reset() acting as
"free this slot" by destructing the GraphInstance and its kernel
state) with a fixed-shape pool: std::vector<GraphInstance> where
each slot carries an atomic SlotState (Available / Reserved /
Active / Releasing). A "dead" slot is one whose state is Available;
the GraphInstance object stays in place, retaining its node-state
vector capacity for the next reuse. Reserved is the producer-claim
state used by the Phase-3 realtime queue (A.2) — see that Note for
the producer-side reserve/prepare/activate flow.

Why the change:

  * No allocation on free. rt_graph_instance_remove and the §2.E
    auto-free path both used to call optional::reset(), which
    destructed the per-node state vectors and freed their memory.
    Under the pool model both paths just set state = Available; the
    vectors stay sized and ready. The next _instance_add into that
    slot reinitialises kernel state in place rather than allocating
    fresh.
  * Sized-once, mutated-by-state. The Phase 3 control queue (A.2)
    will mediate _instance_add / _release / _remove from a non-
    audio thread. Under the optional model, free-then-allocate-on-
    a-different-thread risked tearing or use-after-free in the audio
    callback. Under the pool model the audio thread sees only state
    transitions on slots that already exist.
  * Per-template polyphony as an honest cap. Each MetaDef carries
    a polyphony field; _instance_add returns -1 when the count of
    Active+Releasing slots assigned to that template reaches the cap.
    The runtime does not steal — that's the voice allocator's job.

Pool layout: g.instances is a flat vector across all templates, each
slot tagged with template_id (preserved from §2.D.3). A template's
polyphony cap is enforced by counting at spawn time, not by reserving
a contiguous range. Spawn prefers reuse (first Available slot) over
growth (push_back); growth is construction-only in practice — once
audio is running the live count is bounded by polyphony, every
"removed" slot stays Available, and the queue path will never grow.

Lazy materialisation: an Available slot may have empty node-state
vectors (never used) or full vectors (was previously occupied). On
transition to Active, _template_instance_add resizes the nodes
vector to match the current spec and re-initialises each entry via
init_node_state. A previously-occupied slot reuses its existing
vector capacity; a fresh slot does the first allocation here. Either
way, allocation happens in _instance_add (control thread today,
control queue tomorrow), never in the audio callback.

Slot identity: the C ABI's instance_id is the slot index in
g.instances. instance_count returns g.instances.size() — under the
pool model that's the slot-pool size, not a high-water-mark of
ever-used indices. instance_alive returns 1 iff state is Active or
Releasing (Reserved slots are not yet schedulable, so they read as
not alive). instance_status returns 0 for Active, 1 for Releasing,
and -1 for both Available and Reserved (a caller that did not
perform the reservation has no business observing it).

The auto-created template 0 + instance 0 (rt_graph_create /
rt_graph_clear) keeps the legacy single-template ABI working: the
instance is created with state = Active so _set_control / _read_bus
hit a live target on a freshly-constructed handle.
*/

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

// Set the per-template polyphony cap (max simultaneously-live
// instances of this template). Construction-only.
//
// Values <= 0 are clamped to 1: every template needs room for at
// least one instance, and a zero cap would deadlock callers that
// expect _instance_add to succeed at least once. Unknown template_id
// is a silent no-op. Calling this *after* live instances exceed the
// new cap is allowed but has no immediate effect — already-live
// instances keep running until they release/free naturally; the cap
// gates *future* spawns.
//
// See Note [Pool model] for how the cap interacts with the
// std::vector<GraphInstance> pool model.
void rt_graph_template_set_polyphony(RTGraph *g, int template_id, int polyphony) {
  if (!g) return;
  MetaDef *def = template_at(*g, template_id);
  if (!def) return;
  def->polyphony = polyphony < 1 ? 1 : polyphony;
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
  for (auto &inst : g->instances) {
    // [T:construction]: walk only the slots that already participate
    // in the audio schedule, skipping Reserved alongside Available.
    // A Reserved slot is owned by a producer that may be writing
    // inst.nodes[i] right now; init_node_state would race those
    // writes. (In practice no producer runs during construction,
    // but defense in depth makes the rule legible.)
    const SlotState s = inst.state.load();
    if (s != SlotState::Active && s != SlotState::Releasing) continue;
    if (inst.template_id != template_id) continue;
    init_node_state(
        inst.nodes[to_size(idx)],
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
  // Bus-pool sizing is no longer a side effect of writing this
  // control. Callers that need bus N to exist must call
  // rt_graph_ensure_bus(g, N) explicitly during graph construction.
  // See Note [Explicit bus-pool sizing] below.
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
// Slot allocation rules:
//
//   1. If the named template's per-template polyphony cap is already
//      reached (count of Active + Releasing slots assigned to this
//      template_id == def->polyphony), return -1. The voice allocator
//      will eventually own the stealing policy; the runtime is dumb.
//   2. Scan g.instances for an Available slot, preferring reuse over
//      growth. A reused slot keeps its node-state vector capacity
//      from the previous occupant, which is the whole point of A.1's
//      pool model.
//   3. Only append a new slot if no Available one exists. Growth is
//      construction-only — once audio starts the audio thread sees
//      every slot already; spawning more during audio is the
//      Phase 3 control-queue path, which will be limited to the
//      pre-allocated slots.
//
// Slot reuse means an instance_id may be returned twice over the life
// of the RTGraph (the dead slot is reused after rt_graph_instance_-
// remove or after the §2.E auto-free path), but never concurrently.
int rt_graph_template_instance_add(RTGraph *g, int template_id) {
  if (!g) return -1;

  const MetaDef *def = template_at(*g, template_id);
  if (!def) return -1;

  // Count live slots (Active + Releasing) assigned to this template
  // and remember the first Available slot we see, so the cap check
  // and the slot scan share one pass over g.instances.
  int live_count = 0;
  std::size_t free_slot = g->instances.size();  // sentinel: no slot found
  for (std::size_t i = 0; i < g->instances.size(); ++i) {
    auto &s = g->instances[i];
    if (s.state.load() == SlotState::Available) {
      if (free_slot == g->instances.size()) free_slot = i;
    } else if (s.template_id == template_id) {
      ++live_count;
    }
  }
  if (live_count >= def->polyphony) return -1;

  if (free_slot < g->instances.size()) {
    // Reuse: preserve the GraphInstance's vector capacity, just
    // re-initialise its node state from the (possibly mutated) spec
    // and flip the slot to Active.
    GraphInstance &slot = g->instances[free_slot];
    slot.template_id = template_id;
    slot.silent_blocks = 0;
    slot.block_sink_peak = 0.0f;
    slot.nodes.resize(def->nodes.size());
    for (std::size_t i = 0; i < def->nodes.size(); ++i) {
      init_node_state(slot.nodes[i], def->nodes[i], g->max_frames);
    }
    slot.state.store(SlotState::Active);
    return static_cast<int>(free_slot);
  }

  // No free slot — grow the pool by one. Construction-only path.
  GraphInstance inst = make_instance(*def, template_id, g->max_frames);
  inst.state.store(SlotState::Active);
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

/* Note [Explicit bus-pool sizing]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Until §2.E the bus pool grew implicitly as a side effect of
rt_graph_template_set_default and rt_graph_instance_set_control:
when control 0 of an Out / BusOut / BusIn / BusInDelayed node was
written with a non-negative value, the runtime quietly resized
g.server.output_buses to cover that bus index.

This was convenient for callers (no extra API to learn) but
architecturally messy: a function whose nominal job is "write a
control value" was also resizing a vector that the audio callback
iterates. The Phase 3 control queue — which will ferry per-block
control writes from the voice allocator and MIDI handler — would
otherwise have to either run the resize on the audio thread (a
malloc on the realtime path) or detect-and-defer "growing" writes
(complex). Splitting the responsibility eliminates the question.

Today:
  * rt_graph_ensure_bus(g, bus_index) is the *only* caller-facing
    way to grow the shared pool. Construction-only — must run
    before audio starts.
  * rt_graph_template_set_default and rt_graph_instance_set_control
    purely write the control value. They never resize.
  * The defensive ensures inside rt_graph_process and
    rt_graph_start_audio (size 1 if pool is empty) are kept as
    backstops for the trivial case "single Out, never explicitly
    routed to any bus" so the shortest demo still works.
  * rt_graph_template_add_node retains an auto-ensure for Out: the
    semantic "this template emits to a hardware bus" implies bus 0
    will exist, and the resize is tied to *node-kind addition*, not
    to value writes — so the queue never sees this path.

Callers that route a node to a non-default bus must call
rt_graph_ensure_bus before setting control 0:

    rt_graph_ensure_bus(g, 5);
    rt_graph_template_set_default(g, t, out_idx, 0, 5.0);  // route to bus 5

Tests and Haskell's loadRuntimeGraph / loadTemplateGraph migrated
to this pattern when the implicit growth was removed.
*/

void rt_graph_ensure_bus(RTGraph *g, int bus_index) {
  if (!g || bus_index < 0) return;
  const auto bus = static_cast<std::size_t>(bus_index);
  ensure_output_bus_count(g->server, bus + 1, g->max_frames);
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
  // Gate to Active / Releasing only. Hard-freeing an Available slot
  // is a silent no-op (the slot is already free); hard-freeing a
  // Reserved slot would yank a producer's claim out from under it,
  // dropping in-progress preparation work — the producer is the
  // only legitimate owner of a Reserved slot's lifecycle. See
  // Note [Pool model] and the SlotState comment.
  const SlotState s = g->instances[idx].state.load();
  if (s != SlotState::Active && s != SlotState::Releasing) return;
  // Flip to Available; preserve the GraphInstance object and its
  // node-state vector capacity for the next reuse. No allocation,
  // no destruction.
  g->instances[idx].state.store(SlotState::Available);
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
  // Gate to Active / Releasing only. Releasing an Available slot is
  // a no-op (nothing to release). Releasing a Reserved slot would
  // flip it to Releasing and publish it into the audio schedule
  // *without* the producer's Activate ever having been processed,
  // so process_graph would iterate a slot whose preparation is still
  // in flight. The producer is the only legitimate owner of a
  // Reserved slot's lifecycle; external callers must wait until the
  // queued Activate publishes it before they can ask for release.
  const SlotState pre_state = g->instances[idx].state.load();
  if (pre_state != SlotState::Active && pre_state != SlotState::Releasing) return;

  // The body lives in apply_instance_release so the queued-drain
  // path (apply_control_command::Release) shares the gate-off and
  // state-flip logic without duplication.
  apply_instance_release(*g, g->instances[idx]);
}

int rt_graph_instance_status(RTGraph *g, int instance_id) {
  if (!g) return -1;
  if (instance_id < 0) return -1;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return -1;
  // Active and Releasing have ABI-stable integer values (0 and 1);
  // Available and Reserved both surface as -1 to external callers.
  // Reserved is the producer's claim and is not visible through this
  // entry — a caller that did not perform the reservation has no
  // business observing it as "live". See SlotState comment.
  const SlotState s = g->instances[idx].state.load();
  if (s == SlotState::Active)    return 0;
  if (s == SlotState::Releasing) return 1;
  return -1;
}

int rt_graph_instance_count(RTGraph *g) {
  if (!g) return 0;
  // After A.1 this is the slot-pool size, not a high-water-mark of
  // ever-used indices. The pool grows during construction up to the
  // sum of per-template polyphony caps; once stable, instance_count
  // is constant for the life of the graph.
  return static_cast<int>(g->instances.size());
}

int rt_graph_instance_alive(RTGraph *g, int instance_id) {
  if (!g) return 0;
  if (instance_id < 0) return 0;
  const std::size_t idx = static_cast<std::size_t>(instance_id);
  if (idx >= g->instances.size()) return 0;
  // Alive iff the slot is part of the audio schedule. Reserved slots
  // (claimed by a producer but not yet activated) are not yet
  // schedulable, so they read as not alive — same as Available. See
  // SlotState comment for the full state machine.
  const SlotState s = g->instances[idx].state.load();
  return (s == SlotState::Active || s == SlotState::Releasing) ? 1 : 0;
}

void rt_graph_instance_set_control(
    RTGraph *g, int instance_id, int node_index, int control_index, double value
) {
  if (!g) return;
  // instance_at returns a live or Reserved slot; both are writable
  // from the producer's prep / control path. (Available slots are
  // rejected.) See apply_instance_set_control for the gated body.
  GraphInstance *inst = instance_at(*g, instance_id);
  if (!inst) return;
  apply_instance_set_control(*g, *inst, node_index, control_index, value);
  // Bus-pool sizing is no longer a side effect of writing this
  // control — see rt_graph_ensure_bus and Note [Explicit bus-pool
  // sizing]. The audio thread still must never grow the pool, so
  // when this entry becomes realtime-callable in Phase 3 the value
  // write is the only thing the queue ferries.
}

// (rt_graph_instance_read_bus was removed in the post-§2.E ABI
// cleanup. Under §2.C the bus pool is server-global; an instance-
// keyed bus read added nothing beyond rt_graph_read_bus except a
// liveness gate that the caller can do explicitly. The function name
// is preserved here as a comment so anyone bisecting an old test
// failure to the cleanup commit can find the rationale.)

// ----------------------------------------------------------------
// A.2: realtime ABI — single-producer entries safe to call from a
// non-audio thread while the audio callback is running
// ----------------------------------------------------------------
//
// These entries route mutation through the lock-free SPSC control
// queue that drain_control_queue applies at the top of each
// process_graph block. Single-producer contract: only ONE thread
// may call this group of entries (UI / OSC / MIDI ingress all feed
// *into* the producer thread, not the queue directly). Concurrent
// calls from multiple threads will corrupt the queue.
//
// rt_graph_realtime_reserve does its work synchronously on the
// caller's thread (CAS Available → Reserved + slot prep). The
// other entries enqueue a ControlCommand and return — the work
// happens on the audio thread at the next block boundary.
//
// See Note [A.2: realtime control queue] for the design and memory
// model.

// Reserve and prepare a slot for the named template. Returns the
// slot_id (>= 0) on success, -1 on any failure: null graph, invalid
// template_id, polyphony cap reached, or no Available slot in the
// pool to recycle. Realtime reserve never grows the slot pool —
// growth is construction-only — so callers must ensure the pool is
// pre-warmed during construction (call _template_instance_add N
// times then _instance_remove on each, leaving N Available slots
// of the right shape ready to be reused). Reserved slots count
// toward the polyphony cap.
//
// On success the slot is fully prepared (template_id set, nodes
// vector sized to spec, kernel state freshly initialised, default
// controls inherited from spec) and in Reserved state. The
// producer may then write per-note overrides directly via
// rt_graph_instance_set_control on the Reserved slot, and finally
// publish it into the audio schedule via rt_graph_realtime_activate.
int rt_graph_realtime_reserve(RTGraph *g, int template_id) {
  if (!g) return -1;
  const MetaDef *def = template_at(*g, template_id);
  if (!def) return -1;

  // Single-pass scan: count Active+Releasing+Reserved instances of
  // this template (cap check) and remember the first Available slot.
  // In SPSC the Available slot we observe cannot disappear under us
  // (the audio thread only ever transitions Releasing→Available and
  // Active→Available — both increase the Available count, never
  // decrease it). We can therefore CAS without retries.
  int live_count = 0;
  std::size_t free_slot = g->instances.size();  // sentinel
  for (std::size_t i = 0; i < g->instances.size(); ++i) {
    const SlotState s = g->instances[i].state.load();
    if (s == SlotState::Available) {
      if (free_slot == g->instances.size()) free_slot = i;
    } else if (g->instances[i].template_id == template_id) {
      ++live_count;  // Active, Releasing, or Reserved for this template
    }
  }
  if (live_count >= def->polyphony) return -1;
  if (free_slot >= g->instances.size()) return -1;  // pool not pre-warmed

  // CAS Available → Reserved. Acquire on success synchronizes-with
  // the audio thread's release-store that flipped this slot to
  // Available previously (auto-free or remove). Relaxed on failure
  // means we won't re-load on a contended slot — but in SPSC the
  // CAS can't legitimately fail. If it does, treat it as the
  // contract being violated and silently return -1.
  SlotState expected = SlotState::Available;
  if (!g->instances[free_slot].state.compare_exchange_strong(
          expected, SlotState::Reserved,
          std::memory_order_acquire,
          std::memory_order_relaxed)) {
    return -1;
  }

  // prepare_reserved_slot can throw bad_alloc when the slot is
  // being reused for a template shape larger than its current
  // capacity (the not-pre-warmed path). Catch it here, roll the
  // slot back to Available with release ordering so a subsequent
  // reserver sees a clean state, and report failure as -1. With
  // the recommended pre-warm pattern resize is a no-op and the
  // catch never fires; this is defense in depth so an exception
  // never escapes the extern "C" boundary into producer code.
  try {
    prepare_reserved_slot(*g, g->instances[free_slot], *def, template_id);
  } catch (...) {
    g->instances[free_slot].state.store(SlotState::Available, std::memory_order_release);
    return -1;
  }
  return static_cast<int>(free_slot);
}

// Cancel a reservation, returning the slot to Available without
// publishing it. Guarded CAS Reserved → Available; silent no-op on
// any other state (caller bug or already activated). Used by the
// producer to roll back if rt_graph_realtime_activate's enqueue
// fails. Release on success so a subsequent reserve sees the slot
// in a clean state.
void rt_graph_realtime_cancel(RTGraph *g, int slot_id) {
  if (!g) return;
  if (slot_id < 0) return;
  const std::size_t idx = static_cast<std::size_t>(slot_id);
  if (idx >= g->instances.size()) return;
  SlotState expected = SlotState::Reserved;
  // Failure is silent — Available means already cancelled, Active
  // means the queue already activated us, Releasing means the
  // queue activated then released. None of these are recoverable
  // by cancel; the producer must handle that path differently.
  (void) g->instances[idx].state.compare_exchange_strong(
      expected, SlotState::Available,
      std::memory_order_release,
      std::memory_order_relaxed);
}

// Enqueue Activate(slot_id) for the audio thread to publish at the
// next block. The release-store on write_idx inside enqueue_command
// publishes both this command AND the producer's prior preparation
// of the slot (template_id, nodes, controls, etc.) to the audio
// thread. Returns 1 on success, 0 if the queue is full — on full
// queue the producer should rt_graph_realtime_cancel the slot.
int rt_graph_realtime_activate(RTGraph *g, int slot_id) {
  if (!g) return 0;
  if (slot_id < 0) return 0;
  ControlCommand cmd;
  cmd.kind    = ControlCommand::Kind::Activate;
  cmd.slot_id = slot_id;
  return enqueue_command(g->control_queue, cmd) ? 1 : 0;
}

// Enqueue Release(slot_id). The audio drain gates to Active only;
// Reserved is producer-private and Releasing is already in flight.
// Returns 1/0 as for activate.
int rt_graph_realtime_release(RTGraph *g, int slot_id) {
  if (!g) return 0;
  if (slot_id < 0) return 0;
  ControlCommand cmd;
  cmd.kind    = ControlCommand::Kind::Release;
  cmd.slot_id = slot_id;
  return enqueue_command(g->control_queue, cmd) ? 1 : 0;
}

// Enqueue Remove(slot_id) — hard-free at the next block boundary.
// The audio drain gates to Active or Releasing; Reserved is
// producer-private (the producer should cancel rather than enqueue
// remove on its own reservation). Returns 1/0 as for activate.
int rt_graph_realtime_remove(RTGraph *g, int slot_id) {
  if (!g) return 0;
  if (slot_id < 0) return 0;
  ControlCommand cmd;
  cmd.kind    = ControlCommand::Kind::Remove;
  cmd.slot_id = slot_id;
  return enqueue_command(g->control_queue, cmd) ? 1 : 0;
}

// Enqueue SetControl. The audio drain applies it only to Active or
// Releasing slots — Reserved slots receive their initial controls
// from the producer's pre-enqueue path (direct rt_graph_instance_-
// set_control on the Reserved slot, see the [T:control] exception).
// Returns 1/0 as for activate.
int rt_graph_realtime_set_control(
    RTGraph *g, int slot_id, int node_index, int control_index, double value
) {
  if (!g) return 0;
  if (slot_id < 0) return 0;
  ControlCommand cmd;
  cmd.kind        = ControlCommand::Kind::SetControl;
  cmd.slot_id     = slot_id;
  cmd.node_idx    = node_index;
  cmd.control_idx = control_index;
  cmd.value       = value;
  return enqueue_command(g->control_queue, cmd) ? 1 : 0;
}

} // extern "C"
