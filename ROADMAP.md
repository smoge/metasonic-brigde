# Roadmap

MetaSonic compiles synth graphs in Haskell and executes them
deterministically in C++. The goal is a system with the expressive
power of other music systems, but with stronger ahead-of-time
guarantees: graph topology, execution order, rate propagation, and
resource hazards are all resolved at compile time, not discovered at
runtime.

The architecture has three layers:

| Layer                             | Role                                   | Analog   |
|-----------------------------------|----------------------------------------|----------|
| metasonic-core & bridge           | Create and compile graphs              | sclang   |
| Compiled RuntimeGraph/RegionGraph | Immutable synth template               | SynthDef |
| tinysynth runtime                 | Instance host, buses, voices, MIDI, UI | scsynth  |

Presently, [Cycfi Q](https://github.com/cycfi/q) serves as the DSP
kernel and I/O substrate: oscillators, filters, envelopes, delays,
smoothing, audio streams, MIDI. It does not own graph topology;
MetaSonic does. MIDI input (via Q's typed MIDI stack) and UI control
surfaces are part of the tinysynth layer: live event dispatch and
voice management stay in C++, while Haskell is responsible only for
compiling structure.

---

# Phases

## [x] Phase 0 — Current

A compiled MetaSonic graph builds a subtractive voice (oscillator →
filter → envelope → delay → output), plays it polyphonically from a
MIDI controller, and routes the mix through a shared FX template via
the bus pool. End-to-end demos cover chain, fan-out, saw, noise,
filtered noise, resonant bass, detuned-saw beating, envelope-shaped
pluck, vibrato FM, multi-template send-return, and live-MIDI poly.

Phases:

- Phase 1 — node registry. Twenty-two `NodeKind`s implemented:
    oscillators `SinOsc` / `SawOsc` (PolyBLEP) / `PulseOsc` /
    `TriOsc`, `NoiseGen`, biquads `LPF` / `HPF` / `BPF` / `Notch`
    (Bristow-Johnson), arithmetic `Gain` / `Add`, sinks `Out` /
    `BusOut`, `Env` (`q::adsr_envelope_gen`), `Delay`
    (`q::fractional_ring_buffer`), `Smooth` (`q::dynamic_smoother`),
    `BusIn` / `BusInDelayed`, `PlayBufMono`, `RecordBufMono`,
    `SpectralFreeze`, and `StaticPlugin`. Per-node state unified under
    `std::variant` with `std::get_if` dispatch. See §1 for per-kind
    status.

- Phase 2 — instance / multi-template model. §2.A–§2.E done:
    spec/state split (`MetaDef` + `GraphInstance`), multi-instance
    support with slot reuse, server-global bus pool (single-buffered
    live, double-buffered delayed), multi-template runtime with
    compile-time inter-template precedence derived from
    `BusFootprint`, release-then-free instance lifecycle. §2.F
    (groups) closed as declined.

- Phase 3 — polyphony and MIDI. C++ `VoiceAllocator` over the realtime
    ABI, `MidiVoiceProcessor` translating MIDI 1.0 over Q's typed MIDI
    stack, per-voice CC + pitch-bend through the realtime control
    queue, `Smooth` auto-inserted at control ingress. The `midi-poly`
    demo plays end-to-end from an external controller.

- Phase 4.A/B/C/D — regions, fused kernels, single-input fusion, rate
    metadata. Region overlay shipped across the FFI; seven
    hand-written region kernels (six sink-terminal, one
    buffer-terminal) selected unconditionally with longest-match
    priority; scalar Gain/Add chain fusion via the `FAffineFrom`
    algebra (one scratch slot per fused input); IR-propagated `rnRate`
    plus per-kind/per-port `PortConsumptionRate` metadata in place.
    `Eff` annotations are real for bus and buffer kinds and drive both
    intragraph E_r ordering and inter-template precedence.

- Tooling. Brick TUI inspector (`--inspect` / `--inspect-only`),
    `--fusion-survey` for kernel coverage and rate distribution,
    `tools/rt_graph_bench.cpp` synthetic bench, `--worker-bench`
    Haskell-loaded worker bench, `--corpus-survey`, `--swap-bench`,
    `--plugin-list`, the first `--fusion-cost-lab` slices, and
    `--snapshot-check`.

Parked / deferred:

  - Sample-accurate connected control inputs. Currently block-latched
      from sample 0.

  - Block-rate execution path (§4.D). Per-node output rate is too
      coarse (100 % `SampleRate` on the surveyed corpus); the per-port
      consumption view shows a small but non-zero signal (4
      sample-rate producer nodes across 4 distinct kinds wired only
      into block-latched ports). Metadata is preserved; the runtime
      path waits for the signal to grow.

  - Region-level parallelism (§4.E). Frozen as test/bench-gated. C1d-a
      region work-item metadata, C1d-b serial region-item execution,
      C1d-c sink-free region-item worker dispatch, and C1d-d bench
      instrumentation are all in place; the bench can now distinguish
      C1c band-level wins from C1d-c region-item wins from schedule
      noise. Decision recorded in
      `notes/2026-05-09-phase-4e-worker-turn-on-decision.md` remains
      default-off: the synthetic envelope wins at scale, the
      Haskell-loaded corpus barely crosses 1.0x on the best C1d-c row,
      and no representative workload demands runtime parallelism
      today. No further §4.E implementation work until a real workload
      demands it.

  - Whole-region generated fusion. No generated-runtime path is active
      today. Hand-written DSP bodies plus narrow helpers
      (`SinkAccumulator`, `drive_oscillator`) remain the working
      approach for Phase 4-era kernels. Phase 7 reframes general
      fusion as an evidence-gated compiler backend: cost lab first,
      then fusion IR / planner / executor only where measurements
      justify it.

  - Filtered/stateful kernel expansion. Gated behind survey
      recurrence + benchmark evidence (§4.B.x). Tri/Pulse/Add filtered
      tails parked as singleton-source rows until corpus growth puts
      them past the gate.

---

## Phase 0.5 — Contract & Foundations

[Note after Miller Puckette](blog/posts/2026-03-25-design-notes-from-puckette.md)
flagged that contract drift between the Haskell and C++ sides is
already happening, and that adding more nodes onto an unverified
contract compounds the problem. Phase 0.5 inserts the smallest amount
of work that makes everything after it safer.

### [x] 0.5.1 Machine-checked kindTag agreement

`rt_graph_kind_count()` and `rt_graph_kind_supported(int tag)` are exposed
through the C ABI and a Haskell property test enumerates every `NodeKind`,
computes `kindTag`, and asserts the C++ side recognizes that integer.

### [x] 0.5.2 Stand up the test suite

`test/Spec.hs` carries 71 tests: structural unit tests on the demo
graphs, QuickCheck properties on dense lowering and region invariants
(indices, topological order, count preservation, region partitioning,
rate / effect forward-defense), the kindTag-agreement test from 0.5.1,
an end-to-end FFI round-trip, and a per-kind metadata cross-check
([0.5.5](#055-collapse-per-kind-metadata)).

### [x] 0.5.3 Resolve `BusOut` / `BusIn`

Dropped from `UGen` and the source DSL. Inter-graph shared-bus routing
returns when the Phase 2 instance/server model can back it; until then
`UGen` is total under `ugenView` and contains no constructors that
panic.

### [x] 0.5.4 Document the node-add procedure

Docs now list every site that has to change to add a node kind, in
sibling-form: 5 sites across 2 Haskell files (after the
[0.5.5](#055-collapse-per-kind-metadata) refactor) plus the C++
dispatch in `rt_graph.cpp`. The QuickCheck cross-check in 0.5.2 makes
arity drift between the Haskell metadata table and the constructor
view fail at test time.

### [x] 0.5.5 Collapse per-kind metadata

Per-kind facts now live in two table-shaped sites on the Haskell side:
`kindSpec` in `Types.hs` (tag, rate, effects, arities, label) and `ugenView`
in `Source.hs` (constructor → kind, inputs, controls). `kindTag`,
`inferRate`, `inferEff`, `inferKind`, `lowerInputs`, `extractControls`, and
`dependencies` are all derivations — no per-kind clauses. Adding a kind went
from 10 sites in 3 files to 5 sites in 2 files, with a property test pinning
the two tables together.

---

## Phase 1 — Node Registry (trimmed)

The original Phase 1 listed seven items so the system could describe a
full subtractive voice. The current scope is narrower: **add only the
nodes that make Phase 2 (instance model) testable.** Variations on
existing kernels (more oscillator waveforms, more biquad modes) are
deferred — they're low-risk and can land at any later point.

### [x] 1.1 Replace `SinOsc` internals with `q::sin_osc`

`process_sinosc` uses `q::phase_iterator` for phase accumulation and
`q::sin` (lookup-table) for waveform generation. Phase state lives in
`OscState` via `std::variant`.

### [x] 1.2 Bandlimited oscillators

`SawOsc` (PolyBLEP via `q::saw`), `PulseOsc` (with audio-rate width),
and `TriOsc` are implemented. All three share the `OscState`
`std::variant` slot and reconfigure-on-change for control parameters.

### [x] 1.3 Biquad filter family

`LPF`, `HPF`, `BPF`, and `Notch` are implemented as separate
`NodeKind`s sharing a `q::biquad`-shaped `LPFState`-style slot, each
with reconfigure-on-change semantics. Peaking and shelf modes are
deferred — they're additional rows in the same kernel family and add
no new contract surface.

### [x] 1.4 Envelope generator

Wraps `q::adsr_envelope_gen` as `KEnv` (tag 9). One audio input (gate,
with sample-accurate edge detection at threshold 0.5 → `attack()` /
`release()`) and five controls `[gate_default, A, D, S, R]`. A/D/R are
durations in seconds, S is a linear amplitude in [0, 1]; sustain
*rate* is held at the q default of 50 s (slow background fade during
sustained gate-on).

The kernel uses the same reconfigure-on-change discipline as LPF:
A/D/S/R changes update the q ramp segments at block boundaries, the
envelope_gen is constructed lazily on first process() against the
active sample rate, and the envelope state machine (idle / attack /
decay / sustain / release) lives inside `EnvState`. This is the first
node with non-trivial lifecycle state, so it doubles as the shakedown
for whether the per-node `std::variant` model survives the Phase 2
instance split — without changes, it does.

`Bridge.Source.env` is the user-facing builder;
`app/Main.hs:envPluckGraph` demonstrates `Env` shaping a sine into a
percussive pluck. End-to-end FFI tests assert attack-then-sustain
behavior on a held gate and silence on an idle gate.

### [x] 1.5 Delay line

`KDelay` (tag 8) wraps `q::fractional_ring_buffer` for sub-sample
interpolation. One audio input (signal) and three controls
`[delay_seconds, feedback, mix]`; per-node state lives in
`DelayState`. The buffer is sized at template compile time from a
max-delay default and reused across instances of the template via the
spec/state split.

### [x] 1.6 Bus-routing kinds (`BusOut` / `BusIn` / `BusInDelayed`)

Reinstated alongside the §2.C server-global bus pool. `BusOut` writes
a post-mix into the named bus; `BusIn` reads it live within the same
block (producer must have run earlier in the schedule, enforced by E_r
within a template and by the inter-template precedence DAG across
templates); `BusInDelayed` reads the previous block's value, allowing
one-block-bounded feedback without ordering constraints. The pool is
single-buffered for live reads and double-buffered for delayed reads;
the swap happens once per block at the `Server` level.

### [x] 1.7 `dynamic_smoother` at control ingress

`KSmooth` wraps `q::dynamic_smoother`. The `cc` builder auto-inserts
`Smooth` at control ingress so live MIDI CC writes don't zipper. See
§3.3c for the integration with the per-voice control mapping.

A compiled graph today can describe a subtractive voice with release
behavior and one effect — oscillator → filter → envelope → delay →
output — play it polyphonically from a MIDI controller (Phase 3), and
route the mix through a shared FX template via the bus pool (see the
`send-return` demo).

---

## Phase 2 — MetaDef / GraphInstance Split

Move from "one compiled graph is the whole engine" to "a compiled
graph is an immutable template instantiated many times." Landed in
four sub-phases §2.A–§2.D plus the §2.D send-return demo. Renumbered
from the original §2.1–§2.4 sketch as the work was carved up across
commits.

### [x] 2.A Spec / state split

`MetaDef` (immutable, per-template) carries `NodeSpec[]`,
`Connection[]`, and `default_controls`; `GraphInstance` carries
`NodeInstanceState[]` and per-instance control overrides. Phase
counters, filter memory, ADSR position, and delay buffers all live in
the instance, not the spec. This is the load-bearing refactor that
makes everything afterward possible.

### [x] 2.B Multi-instance support

`rt_graph_instance_add` / `_remove` / `_alive` / `_count` plus
per-instance `_set_control` / `_read_bus`. Instances are stored in a
`std::vector<std::optional<GraphInstance>>` with slot reuse (dead
slots are filled before the vector grows), so `instance_id` is dense
within the slot range and stable for the life of the instance. Each
instance runs the same spec with its own kernel state.

### [x] 2.C Server-global buses

The bus pool moved out of the per-instance struct into a `Server`
owned by the runtime. Live-read buses are single-buffered;
delayed-read buses are double-buffered with a swap-and-clear at block
boundaries. Pool is shared across all instances of all templates —
there is no per-instance or per-template scope for bus reads. This is
what unlocks `voice → fx` routing across separate compiled graphs.

### [x] 2.D Multi-template runtime

§2.D.1 fixed `inferEff` so `Out` carries `BusWrite n` (was `Pure`),
making the effect vocabulary honest about hardware-bound output too.

§2.D.2 [`Bridge/Templates.hs`](../src/MetaSonic/Bridge/Templates.hs):
`compileTemplateGraph :: [(String, SynthGraph)] -> Either String
TemplateGraph` extracts a `BusFootprint` (writes / live-reads /
delayed-reads) per template from `irEffects`, builds a precedence DAG
where `T_a` precedes `T_b` iff `bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅`, and
topo-sorts it. Delayed reads do not contribute, exactly as within a
single graph. Cycles → compile error.

§2.D.3 turned `RTGraph` into a vector of `MetaDef`s with a flat
instance table tagging each `GraphInstance` by `template_id`.
`process_graph` iterates templates in registration (= execution)
order, processing every live instance of each template before
advancing. The runtime never reorders. Legacy single-template entries
(`rt_graph_add_node`, `rt_graph_set_control`, `rt_graph_connect`) are
preserved as thin shims operating on auto-created template 0.

The §2.D demo (`send-return`) wires a saw-with-vibrato voice template
that writes bus 7 and a low-pass FX template that reads bus 7 and
writes hardware bus 0; `compileTemplateGraph` schedules voice before
fx without any user-visible group object.

### [x] 2.E Instance lifecycle: release-then-free

`rt_graph_instance_release` flips a slot to `Releasing`, lets
envelopes complete their tail, and reclaims the slot once the instance
produces silence across a configured threshold + window. Hard-free
(`rt_graph_instance_remove`) remains available for deliberate cuts
(panic stops, voice stealing in extremis). A polyphonic stress test
exercises many voices with staggered release and slot reuse.

### 2.F Groups — DECLINED

SuperCollider-style Groups are declined as a runtime primitive for
now. The jobs they usually perform, namely ordering, routing, coordinated
instance control, and lifecycle management, should remain consequences
of compiled templates, bus-footprint precedence, voice allocation, and
the release-then-free instance model rather than a mutable runtime tree.

Reevaluate this only if a concrete workflow cannot be expressed cleanly
through the compiler-owned model.

---

## Phase 3 — Polyphony and MIDI

Real-time voice allocation driven by MIDI input.

### [x] 3.1 Voice allocator

A C++ `VoiceAllocator` over the realtime ABI maps note-on events to
`rt_graph_template_instance_add` (Reserve / Activate via the SPSC
queue) and note-off events to `rt_graph_instance_release` (§2.E).
Voice stealing policy lives here; hard-free is reserved for stealing
under pressure.

### [x] 3.2 Q MIDI integration

`MidiVoiceProcessor` is a MIDI-1.0 → `VoiceAllocator` translator built
on Q's typed MIDI stack (`note_on`, `note_off`, CC, pitch-bend,
processor concept, input stream dispatch). Note events stay in C++;
Haskell compiles structure, C++ owns live note lifetimes. Haskell does
not send MIDI to tinysynth, unlike SC3. The Q `q_io` MIDI sources are
vendored locally with two patches.

### [x] 3.3 Per-voice control mapping

3.3a wired per-voice CC + pitch-bend dispatch through the realtime
control queue. 3.3b stabilized the live-MIDI demo lifecycle. 3.3c
added `KSmooth` (`q::dynamic_smoother`) and made the `cc` builder
auto-insert it at control ingress so CC writes don't zipper. The
live-MIDI poly demo (`midi-poly` entry) plays a polyphonic MetaSonic
instrument from a MIDI controller, end-to-end.

---

## Phase 4 — Fusion, Regions, and Rate Propagation

Move scheduling granularity from individual nodes to fused regions, in
two complementary tracks.

**Single-input rewrite fusion (§4.C):** a consumer's input read
absorbs a producer's per-block work via the `RFused` algebra, the
producer is elided but remains control-addressable, and one scratch
slot per fused input keeps memory cost bounded. Both scalar `Gain`
(4.C.1) and scalar `Add` / bias (4.C.2) collapse into the same
`FAffineFrom` chain-walk; chains compose end-to-end.

**Region-level execution (§4.A / §4.B / §4.D; §4.E frozen):** §4.A's
region overlay and §4.B's hand-written region kernels are now real,
not conceptual. The region-kernel surface covers buffer-terminal
(`RSawLpfGain`) and sink-terminal (3-node `RSinGainOut` /
`RSawGainOut` / `RNoiseGainOut`; 4-node `RSawLpfGainOut` /
`RBusInLpfGainOut` / `RNoiseLpfGainOut`) shapes. Selection runs
unconditionally inside `compileRuntimeGraph`; longest-match priority
handles 3- vs 4-node overlap. `--fusion-survey` and the microbench
under `tools/rt_graph_bench.cpp` are the evidence infrastructure that
gates kernel additions; the same gate currently parks Tri/Pulse/Add
filtered tails as low-signal singletons.

§4.D landed as descriptive infrastructure. §4.D.1 carried the
IR-propagated `rnRate` into `RuntimeNode` and added a survey "Rate
distribution" section, which reported 100% `SampleRate` on the corpus
and proved per-node /output/ rate is too coarse on its own to license
block-rate regions. §4.D.2 added per-kind / per-port consumption-rate
metadata (`PortInfo` / `PortConsumptionRate` — `PortBlockLatched` for
filter freq/q, `PortIgnored` for oscillator phase,
`PortSampleAccurate` for everything else) and a producer-grouped
opportunity headline. The empirical signal is small (4 sample-rate
producer nodes across 4 distinct kinds in the surveyed corpus). A
runtime block-rate execution path is parked until that signal grows.

§4.E is frozen as a default-off runtime substrate. The schedule
metadata, global schedule, deterministic reduction substrate,
test-gated Free-band worker dispatch, C1d region-item dispatch,
synthetic bench, and Haskell-loaded worker bench are now in place. The
current turn-on decision is negative: no representative workload
justifies enabling worker dispatch by default. §4.D's descriptive
metadata remains in place and feeds future scheduling decisions; the
block-rate execution path stays parked until the per-port survey signal
grows.

What's no longer part of Phase 4: whole-region generated fusion.
Hand-written DSP bodies plus narrow helpers (`SinkAccumulator`,
`drive_oscillator`) remain the working approach for the current kernel
set. Any move from hand-written region kernels to compiler-generated
fusion now belongs to Phase 7, and starts with measured cost-model
evidence rather than runtime codegen.

### [x] 4.A Region formation

`formRegions` produces a contiguous, rate-coherent partition of the
runtime graph; `RuntimeRegion` carries the dense member list, region
rate, and inter-region dependency edges. The runtime ships the region
overlay across the FFI and `process_instance` dispatches on it. Future
work (§4.E) consumes this overlay. Generated fusion does not consume it
yet; Phase 7 owns that future path.

### [x] 4.B Q inside region kernels

Hand-written fused kernels run through `process_instance`'s region
dispatch. The current set, with the shape each one claims:

| Kernel             | Arity | Shape                              | Class       |
|--------------------|-------|------------------------------------|-------------|
| `RSawLpfGain`      | 3     | `[KSawOsc, KLPF, KGain]`           | buffer-term |
| `RSinGainOut`      | 3     | `[KSinOsc, KGain, /sink/]`         | sink-term   |
| `RSawGainOut`      | 3     | `[KSawOsc, KGain, /sink/]`         | sink-term   |
| `RNoiseGainOut`    | 3     | `[KNoiseGen, KGain, /sink/]`       | sink-term   |
| `RSawLpfGainOut`   | 4     | `[KSawOsc, KLPF, KGain, /sink/]`   | sink-term   |
| `RBusInLpfGainOut` | 4     | `[KBusIn, KLPF, KGain, /sink/]`    | sink-term   |
| `RNoiseLpfGainOut` | 4     | `[KNoiseGen, KLPF, KGain, /sink/]` | sink-term   |

`/sink/` is `KOut` or `KBusOut` — both dispatch to the same
sink-absorbing path; the kernel body is bus-kind-agnostic.
Longest-match priority resolves the 3-vs-4 overlap (e.g. `[Saw, LPF,
Gain, Out]` is claimed by `RSawLpfGainOut`, not `RSawLpfGain` + a
trailing per-node `Out`).

Sink-terminal kernels are the proven class: they remove an extra
per-node dispatch /and/ inline the sink's bus accumulation +
`block_sink_peak` update, which is what makes the fusion measurable.
Buffer-terminal is useful but borderline; the biquad cost dominates
the dispatch cost on its own.

`RBusInLpfGainOut` is the first non-oscillator producer kernel — the
source is a bus reader rather than a generator with phase or PRNG
state. It claims the `BusIn → LPF → Gain → /sink/` return-tail shape
that arises naturally in cross-template send/return ensembles.

`RNoiseLpfGainOut` is the noise counterpart of `RSawLpfGainOut`: the
producer is a `q::white_noise_gen` xorshift PRNG whose state the
kernel pulls one sample at a time, mirroring the per-node
`process_noisegen` cadence (the load-bearing bit-equivalence pin). It
was unparked after the corpus-first → ranked-table → gate → benchmark
loop reached `missed=4, sources=4` and the benchmark landed at median
~1.25x. Tri/Pulse/Add filtered tails stayed singleton-source
`no-signal` rows in the same scan and remain parked.

#### 4.B.x Kernel-add gate

Filtered/stateful kernel additions go through a four-clause gate. This
is the discipline that kept `RNoiseLpfGainOut` parked while the survey
signal was 3 missed across 3 graphs (insufficient sources), and that
triggered the unparking once corpus expansion brought the count to
`missed=4, sources=4` in the ranked missed-shape table. Tri/Pulse/Add
stay parked at singleton sources by the same gate.

1. **Survey recurrence.** The shape recurs across multiple distinct
   topologies in `--fusion-survey`'s ranked missed-shape table.
   Concrete threshold: `missed ≥ 3 ∧ sources ≥ 3`. The `sources`
   column counts distinct `srDemo` strings; multi-template ensembles
   count as one source even if several templates contribute the same
   shape. Single-graph shape probes contribute to matcher coverage but
   not to kernel-add justification.

2. **Benchmark threshold.** The fused kernel hits the sink-kernel win
   range (roughly 1.2x–1.9x speedup over the stripped node-loop
   baseline) on `tools/rt_graph_bench.cpp`. Smaller wins than
   `RSawLpfGainOut`'s ~1.3x deserve scrutiny; the kernel pays ongoing
   maintenance cost forever.

3. **Stripped node-loop baseline equivalence.** Bit-equivalence tests
   use `stripRegionKernels` to force per-node dispatch on the same
   compiled graph, then compare bus output sample-for-sample against
   the kernel's render. Anything looser (kernel-vs-kernel, approx
   float compare) is a coverage gap.

4. **Edge-case parity, including invalid-input paths.** The kernel
   handles every per-node baseline behavior, including the cases that
   nominally look like "no work this block." `RBusInLpfGainOut`'s
   near-miss was exactly this: an early return on invalid `busin.bus`
   froze the LPF state, which then desynchronized from the per-node
   baseline on the next valid block. Stateful filters cannot skip the
   loop; they must advance state on zero input, the same way the
   per-node chain would.

### [x] 4.C Single-input rewrite fusion (RFused algebra)

Per-port rewrites that elide a single-consumer producer node by
absorbing its per-block work into the consumer's input read. The
elided node stays in `rgNodes` with `rnElided = True` so its
`NodeIndex` and controls remain addressable through `set_control` and
the realtime control queue; the runtime reads each control live at
fused-input evaluation time, so chained-fused output is bit-identical
to the unfused kernel chain.

#### [x] 4.C.1 Scalar Gain fusion (single-edge + chain)

Step C (a-g): `KGain` nodes whose work is to multiply a
single-consumer signal by a control-rate scalar are elided into the
consumer's input through `RFused FScaleFrom` (length 1) or `RFused
FScaleChainFrom` (length ≥ 2, runs of consecutive scalar Gains feeding
one non-candidate sink). The C++ resolver applies each scale in
source-to-sink order with the same `sanitize_finite(float(...), 1.0f)`
discipline as `process_gain`, so float rounding is preserved. One
scratch slot per fused input regardless of chain length. Live behind
the demo runner's `--fused` flag.

#### [x] 4.C.2 Scalar Add / bias fusion

Scalar `Add` (one signal input, one `RConst` bias on the other port)
folded into the same chain-walk as scalar Gain. The two shapes share
the heterogeneous `FAffineFrom` chain descriptor: runs of scalar Gains
and scalar Adds in any order — `src → Gain(k) → Add(b) → consumer` and
reverse — collapse end-to-end into one fused input with one scratch
slot. Audio-rate Adds stay dispatched, exactly as audio-modulated
Gains do.

Tests cover bit-equivalence with unfused, live `set_control` on the
elided Add node moving the bias, the gate stopping at audio-rate Add,
and Gain+Add chain composition.

### 4.D Block-rate regions

Existing IR-level rate propagation
(`MetaSonic.Bridge.IR.propagateRates`) is coherent: each node's output
rate is the join of its kind floor with its inputs' rates. Producer
floors (`KSinOsc`, `KSawOsc`, `KNoiseGen`, `KLPF`, `KEnv`, `KBusIn`,
…) are `SampleRate`, so any reachable consumer of an audio producer
also lifts to `SampleRate`. That part of the lattice is not broken; it
answers a different question than block-latch optimization needs.

The §4.D problem is that *node output rate* alone is too coarse to
license block-rate regions. A `KGain` whose only consumer is the
absorbed sink is sample-rate by output, but its `amount` slot may be a
scalar `CompileRate` constant; an `LPF`'s `freq` and `q` are
block-latched by the C++ runtime even when wired to a sample-rate
source (the kernel reads only sample 0 of the input span and
reconfigures `q::lowpass` once per block).

The decisive metadata for §4.D is *per-input consumption policy at the
destination port*, not the source's output rate. §4.D.1 (preserving
`rnRate` into `RuntimeNode` and surveying its distribution) confirmed
this empirically: 100 % `SampleRate` across the entire surveyed
corpus. Per-node output rate cannot be the lever.

§4.D.2 landed as the descriptive follow-up. It added per-kind /
per-port consumption-rate metadata (`PortConsumptionRate` / `PortInfo`
/ `portInfo` in `MetaSonic.Types`; helpers in
`MetaSonic.Bridge.Compile.EdgeRates`), an edge-rate survey joining
each `rnInputs` edge against the destination's read policy, and a
/producer-grouped/ opportunity headline. The producer grouping is
load-bearing: a sample-rate producer that feeds both a
`PortBlockLatched` port and a `PortSampleAccurate` port must remain
sample-rate to serve the sample-accurate consumer, so it is not an
opportunity even though one of its edges lands in a
non-sample-accurate bucket. `sampleRateOpportunityProducers` applies
the per-producer rule per graph; the survey concatenates the lists
across rows. Phase ports are classified `PortIgnored` (the runtime
silently drops `RFrom` edges to oscillator port 1) and excluded from
the count.

Empirical signal on the surveyed corpus: 4 sample-rate producer nodes
across 4 distinct kinds (`KAdd`, `KEnv`, `KSmooth`, `KSinOsc`) qualify
as opportunities, out of 235 `RFrom` edges total. That's small but
non-zero, and the producer-kind diversity argues against treating it
as a corner case. The decision: preserve the metadata, keep watching
the number, and park a runtime block-rate execution path until the
signal grows. New kernels are not the lever either — the ranked
missed-shape table still classifies Tri/Pulse/Add filtered tails as
low-signal.

Rate-distinguished regions remain a precondition for §4.E's
parallelism story to be as cheap as possible — a sample-rate region
driven entirely by control-latched inputs has lower per-block work
than one driven by audio inputs, and the scheduler should know that
when packing regions onto threads — but §4.E does not strictly require
§4.D and can ship with conservative scheduling. The §4.D descriptive
metadata stays in place to feed whatever decisions §4.E eventually
makes.

### 4.E Region-level parallelism — runtime substrate test-gated, default off

Independent regions (no shared bus hazards) can run on separate
threads. Another design difference from sc3/supernova: this is cleaner
than SuperNova's ParGroup model because hazard analysis is structural,
not manual — `BusFootprint` already records each template's writes /
live-reads / delayed-reads, and the same shape can be lifted to
per-region granularity.

Current status:

1. [x] **Region scheduling metadata.** Per-region `BusFootprint`
   metadata, `regionDependencies`, and the live-bus barrier policy are
   in place. `KBusIn`, `KOut`, and `KBusOut` stay on the barrier path
   for normal scheduling; `KBusInDelayed` does not induce same-block
   ordering.

2. [x] **Deterministic linear fallback.** `regionSchedule` validates
   dense region order, preserves barrier positions, topologically
   sorts free segments, and remains the stable fallback shape for
   loaders and runtime comparison.

3. [x] **Layered descriptive plan.** `layeredRegionSchedule` exposes
   `ScheduleStep`s: pinned barriers plus stable free layers. Each
   `FreeLayer` carries explicit `SharedWriteHazard`s for same-layer
   writes to the same bus.

4. [x] **Survey split.** `--fusion-survey` distinguishes full-layer
   width runnable without reduction (`runW` / `tplRunW`) from width
   that needs deterministic reduction or serialization (`redW` /
   `tplRedW`), with hazard counts (`haz` / `tplHaz`). This remains
   descriptive evidence, not a turn-on policy.

5. [x] **Deterministic bus-reduction substrate.** Test-gated. Sink
   writes route through `BusWriteTarget`; canonical writer slots are
   reserved at dispatch boundaries; contribution storage is sized from
   polyphony and sink-writer counts; and reduction mode can
   capture/fold writer-slot buffers in canonical order. Direct and
   reduction modes are bit-identical across hand-built C++ cases and
   the Haskell demo / survey corpus.

6. [x] **Global schedule ABI and serial executor.** Opt-in. Haskell
   loaders ship per-template schedule-step metadata to the runtime;
   the runtime builds a per-block global schedule and bands it into
   barriers / free bands. An opt-in serial executor consumes those
   bands while preserving the legacy executor as fallback for
   metadata-free construction paths.

7. [x] **Worker-pool Free-band dispatch.** Test-gated. The runtime
   owns a worker pool configured through the test ABI. Eligible Free
   bands dispatch through it under
   `rt_graph_test_set_global_schedule_execution` +
   `rt_graph_test_set_worker_pool_size`; direct-mode sink bands
   serialize explicitly, while reduction-mode sink bands can use
   deferred per-slot folding after the worker join. C1c tests run the
   full T-9 corpus under `pool_size=3` and preserve byte equivalence.
   The dispatch primitive now publishes work and joins with atomics
   only on the audio thread; thread start/stop remains a
   construction-time operation.

8. [x] **Bench, corpus refresh, and turn-on decision.** Default-off.
   The C++ synthetic bench and Haskell-loaded worker bench are in
   place. Synthetic sink-free Free-band compute only wins at enough
   width / block work; reduction-backed sink dispatch still loses on
   the measured grid. Targeted free-only probes are positive and keep
   C1d investigation alive, but no row supports default-on worker
   scheduling. Current numbers and the standing decision live in
   `notes/2026-05-09-phase-4e-worker-turn-on-decision.md`.

9. [x] **C1d-a region work-item metadata.** The runtime now expands
   each `GlobalScheduleEntry` into `RegionLayerWorkItem`s, one per
   scheduled region item, with precomputed writer-slot subranges and
   counters that distinguish sink-free C1d candidates from
   sink-bearing serialized groups. Capacity is reserved off the audio
   path using the same `max(polyphony, occupied)` discipline as the
   global schedule. C++ tests pin non-contiguous region ordinals,
   writer-slot subranges, lowered-polyphony capacity, mixed sink-free
   / sink-bearing `has_sink_writer` OR logic, and reset behavior.
   Review note:
   `notes/2026-05-09-c1d-a-region-work-item-metadata-review.md`.

10. [x] **C1d-b serial region-item executor.** Test-gated. When
   `rt_graph_test_set_global_schedule_execution` is enabled and a Free
   band stays on the audio thread, the serial executor consumes the
   per-entry `RegionLayerWorkItem` slice instead of re-reading
   `schedule_step_regions`. Barrier bands and the C1c worker-pool path
   keep the legacy whole-entry executor. A test-only counter proves
   non-vacuous region-item execution, and C++ equivalence tests plus
   the Haskell T-9 corpus preserve byte-equivalence.

11. [x] **C1d-c sink-free parallel region items.** Test-gated.
   Sink-free multi-region `FreeLayer` entries can dispatch their
   region work items through the existing worker pool when
   global-schedule execution and a worker pool are enabled.
   Sink-bearing, mixed, singleton, and pool-size-1 entries stay on the
   C1d-b serial path. Test-only C1d-c counters prove region-item
   worker dispatch separately from C1c band-level dispatch, and C++
   tests cover legacy equivalence, reduction equivalence, fallback
   cases, and per-block counter reset. The standing default-off
   decision remains unchanged.

12. [x] **C1d-d bench instrumentation and decision refresh.**
   Default-off. `--worker-bench` and the C++ synthetic bench now
   expose `c1d_parallel_entries` / `c1d_parallel_items` per row plus a
   `best_c1d_worker_speedup` summary; the synthetic bench gained a
   dedicated `RegionItems` shape (single-instance, multi-region
   sink-free FreeLayer) so the C1d-c path can be measured without C1c
   contamination. The bench can now partition every row into C1c
   (`parallel_bands > 0`), C1d-c (`parallel_bands == 0 ∧
   c1d_parallel_entries > 0`), or schedule/serial noise. Synthetic
   `RegionItems` reaches 2.20x at width 32 / block 512 / pool 4;
   Haskell-loaded best C1d-c is 1.14x on a single targeted probe with
   another row losing. Decision in
   `notes/2026-05-09-phase-4e-worker-turn-on-decision.md` remains
   default-off.

**Phase 4.E is now frozen as test/bench-gated.** No further §4.E
implementation work — no C1d-e, no public switch, no additional
synthetic workloads, no policy prototype — until a real workload
appears whose region-layer shape and DSP weight argue for runtime
parallelism. The bench is honest enough to recognize such a workload
when it shows up; it is not honest enough to manufacture one.

When a workload candidate does appear, the next §4.E slice is:

1. **Identify the load-bearing user.** Name the demo, plugin host,
   pattern engine, or hosted graph that the workload comes from. A
   benchmark row added purely to feed the bench is circular evidence
   and is not authorized as a workload candidate by this freeze.

2. **Prove the shape and weight.** Show the row registers as C1c or
   C1d-c (counter-confirmed) and that legacy direct execution costs
   enough block time to put a worker speedup near or above the
   synthetic envelope (`RegionItems` at comparable width / block).

3. **Replace the decision record.** Open a successor to
   `notes/2026-05-09-phase-4e-worker-turn-on-decision.md` that names
   the corpus, threshold, and proposed switch policy. Do not extend
   that note in place — the freeze is recorded against its current
   text.

**The C0–C1 substrate has value independent of parallel dispatch.**
Even if Phase C parallelism never ships, the global schedule, banded
view, lifecycle hoist, and writer-slot pre-assignment are the
substrate for deterministic bus reduction (§4.E.2 fold ordering),
schedule introspection (`--fusion-survey` corpus FreeLayer-width
table), and future RCU-style topology swap (Phase 5). A "no
parallelism" outcome would not retire that infrastructure.

---

## 5 — Hot Graph Replacement

Replace a running MetaDef with a recompiled version **without audible glitches**.

**Status: hot-swap substrate v1 complete.** RCU protocol (§5.1),
copy-safe state migration via caller-tagged keys + slot-index
identity (§5.2), Haskell producer ergonomics (§5.3), swap-bench
instrumentation (§5.3.C), and template identity precondition
(§5.4.B) all shipped. State preservation is partial today — Env,
Delay, and Smooth state default-init across a swap (§5.2); an
allocation-free prewarm / custom-copy slice for those kinds is the
remaining work toward the "without audible glitches" goal for graphs
that depend on those state types. The two open API items — §5.3.D
blocking wait and §5.4.C producer-side mapping helpers — stay
deferred. Both are explicitly gated on real-producer evidence;
pulling them ahead of that signal would be the same circular-evidence
trap the §4.E freeze warns against. Phase 6.A is the first such
producer candidate; revisit these only if 6.A's corpus or 6.B's OSC
surface demonstrates concrete friction.

### [x] 5.1 RCU-based topology swap

The runtime now has the RCU protocol substrate plus
real world-payload replacement:

- `RTGraphSwap` publish / block-boundary install / retire / collect is
  pinned by C++ tests.

- The swappable world lives in `RTGraphState` behind `RTGraph::active`.

- A producer can build a separate offline `RTGraph`, move its world
  into a swap with `rt_graph_prepare_swap_from_graph`, and install it
  without stopping the target audio handle.

State migration is implemented by §5.2 for caller-tagged nodes and
slot-index-matched live instances. The old world is moved into the
collected swap and destroyed off-audio.

### [x] 5.2 State migration

The first migration policy is caller-supplied node tags plus
slot-index instance identity:

- Haskell `tagged` migration keys survive lowering and FFI loading as
  1..16 non-NUL bytes.

- `rt_graph_prepare_swap_from_graph` builds the migration plan off-audio.

- The audio-thread install loop copies matched controls, copy-safe DSP
  state (oscillators, noise, biquads), and live-slot lifecycle
  metadata without allocation.

- Env, Delay, and Smooth DSP state remain default init until a later
  prewarm/custom-state slice makes them allocation-free to migrate.

### [x] 5.3 Producer ergonomics

The Haskell FFI now exposes the swap protocol without forcing callers
to manually juggle every ownership edge:

- `hotSwapRuntimeGraph` / `hotSwapRuntimeGraphFused` build a next
  single-template world in an offline runtime handle sized by an
  explicit builder-capacity hint, then publish it to a live target
  without calling `rt_graph_clear`.

- `hotSwapTemplateGraph` / `hotSwapTemplateGraphFused` provide the
  same helper for template ensembles.

- `BuilderCapacity`, `MaxFrames`, `TimeoutMs`, and `SwapGeneration`
  aliases label the adjacent integer roles in the Haskell API. They
  are documentation, not type-safety; use newtypes later only if
  callers start mixing them up. `SwapGeneration` stays Haskell-facing
  `Int`; the raw C counter remains `int`/`CInt` at the FFI boundary.

- `collectRetiredSwapStats` reaps the installed retired swap, returns
  the Phase 5.2 migration counters, and disposes the old world
  off-audio.

- Failed publish cancels the prepared swap before returning, so
  callers do not leak a next-world payload when the target already has
  a swap in flight or a retired swap waiting.

- `waitForSwapGeneration` and the `hotSwap*AndWait` helpers add the
  live-producer protocol: publish, wait for the install generation to
  advance with a timeout, reap stats, then resume realtime commands
  against the new world. These helpers are v1 single-producer /
  single-collector conveniences; concurrent producers need a stronger
  attribution token than "generation advanced."

Edit a graph in the Haskell DSL, recompile, and hear the change
without restarting audio.

### [x] 5.3.C Swap-bench instrumentation

Measured before deciding whether to add more synchronization
surface.

- `--swap-bench` is wired beside `--fusion-survey` and
  `--worker-bench`, backed by `MetaSonic.App.SwapBench`.

- The corpus is fixed and deterministic: unchanged graph, tagged
  oscillator, tagged biquad, lifecycle-only graph (Env + release →
  Releasing slot), fused graph, and two-template ensemble.

- 5.3.C2 adds 11 repetitions per row in fresh `withRTGraph` handles.
  Timing is reported as min / median / max in nanoseconds; counters
  and `blocks_to_install` must be identical across runs and match the
  row's expected signature. The bench aborts on drift or stable wrong
  counters, because counters remain the path-proof signal.

- Observed envelope (medians, single-template ~5 µs prepare+publish,
  two-template ~8.5 µs, collect 0.3–0.5 µs, install reliably one block
  on the offline driver) is recorded in [rcu hot-swap
  note](notes/2026-05-10-phase-5-rcu-hot-swap-design.md) §4.2.

**Decision: 5.3.D (`rt_graph_wait_swap_installed`) deferred.** The
bench shows producer cost is microseconds and install is one process
block under the offline driver. A C-side blocking wait could at most
reduce producer notification granularity; it would not make the audio
thread install before a block boundary. Revisit only if a real
producer demonstrates that polling is the wrong abstraction.

### 5.4 Producer identity after install

Producer retargeting is a separate problem from Phase 5.2's internal
migration plan:

- Node migration keys let the runtime copy old state to new nodes, but
  they do not expose a post-install `MigrationKey -> NodeIndex` query.
  v1 keeps that mapping producer-owned: derive it from the new
  `RuntimeGraph` / `TemplateGraph` that the producer just compiled.

- Bus identity remains numeric and caller-owned in v1. There is no bus
  migration key, no bus-content preservation, and no automatic bus
  remap in the runtime.

- Template identity is the runtime-side gap. State/lifecycle migration
  assumes a stable semantic template at each `template_id`; reordering
  templates can violate that while looking structurally valid. The
  design recommends turning this into a prepare-time precondition.

Note: [producer identity note](notes/2026-05-10-phase-5-4-producer-identity-after-install-design.md)

### [x] 5.4.B Template identity precondition

- C++: `MetaDef::identity` (16-byte fixed-width token, same shape as
  the node migration key) plus a construction-only ABI entry
  `rt_graph_template_set_identity(g, template_id, key, key_len)`.

- `rt_graph_prepare_swap_from_graph` adds a precondition: for every
  live (Active or Releasing) old instance, if the old and new defs at
  that `template_id` both carry an identity, the tokens must match or
  prepare returns `nullptr`. Empty tokens on either side opt out, so
  legacy single-template flows and gradual adoption stay permissive.

- Haskell: `loadTemplateGraph` and `loadTemplateGraphFused` ship
  `tplName` through the new ABI as the identity. Names that exceed 16
  bytes or contain NUL fail during the pre-clear validation gate, so
  the currently loaded graph is preserved.

- Counter / test coverage: 5 doctest cases (setter validation,
  matching tokens succeed, differing tokens reject,
  missing-token-on-one-side permissive, no-live-slot bypass) and 4
  Haskell tests (same-name same-order swap publishes; reordered
  named-template swap rejects before install and lets a same-shape
  recovery publish succeed; overlong identity fails before clear;
  fused reordered swap rejects).

### 5.4.C Producer-side mapping helpers — optional

Producer-side mapping helpers for resolving post-install node /
control coordinates from migration keys, and a small set of
name-stable bus helpers. Defer until a real caller hits the friction;
Haskell-side `RuntimeGraph` knowledge is sufficient for v1 producers.

---

## Phase 6 — Extended DSP and Ecosystem

Phase 6 collects five formerly-bundled workstreams as named sub-phases. 6.A
through 6.D are closed (pattern producer + OSC control surface + buffer I/O +
first spectral kind). 6.E (plugin hosting) is the open final boundary test:
slice 1 landed the `KStaticPlugin` surface and the silence skeleton, slice 2
landed real `Identity` dispatch with `plugin_call_count` /
`invalid_plugin_call_count` counters, and slice 3 records the parked metadata
follow-up decision. Ordering reflects two project rules: cheapest unblocker for
the parked §4 corpus signals first, and items whose design needs its own pass
before code go after items whose surface is already analogous to something
shipped.

### Phase 6.A — Sequencing / Pattern Layer (closed at contract level)

A Haskell-side producer of compiled graphs and timed control / hot-swap
events. No new C++ runtime substrate, no new DSP nodes, no audio-thread
symbolic lookup. Starting here is twofold: it lands without straining
the C++ surface, and it generates the corpus that several Phase 4
freezes are waiting on (§4.B.x kernel-add gate, §4.D block-rate
signal, §4.E worker turn-on). A pattern-system prototype exists
outside the current tracked bridge tree; 6.A formalizes the
producer-vs-runtime boundary before any prototype is promoted into
this repo.

#### [x] 6.A.1 Design note

Settles four bounds before any code lands:

- **Corpus naturalness.** Patterns produce shapes natural for music-
  making. The corpus must not be engineered to feed fusion /
  parallelism / hot-swap gates — that's the same circular-evidence
  trap §4.E names.
- **Verification meaning.** "Compatibility with existing
  `--fusion-survey`, `--worker-bench`, `--swap-bench`" means the
  corpus produces shapes those surveys already recognize, not just
  that the surveys run without crashing on the new artifacts.
- **In-scope vs out-of-scope.** Pattern is a *producer* of compiled
  graphs and timed events. It is not a runtime scheduler in Haskell;
  it does not own audio-thread state; it does not introduce a new DSL
  layer between user and `SynthGraph`.
- **Swap-bench role.** Once patterns drive real hot-swaps,
  `--swap-bench` becomes production-load measurement instead of
  synthetic. That may surface 5.3.D or 5.4.C friction sooner than the
  §5 freeze anticipated; treat that as a positive signal, not a
  regression.

Note: [Phase 6.A pattern design](notes/2026-05-10-phase-6a-pattern-design.md).

#### [x] 6.A.2 Minimal pattern corpus

A small, fixed, deterministic battery — analogous to the §4 demo
battery — covering recurring control changes, bus send/return
patterns, polyphonic template ensembles, hot-swap edits across
generations, and natural-music graph families that incidentally cover
fusion / parallelism / hot-swap shapes. Corpus design is not on the
audio thread.

#### [x] 6.A.3 Verification before "musical" surface

Three layers of verification:

- **Deterministic event expansion.** Pinned in 6.A.2 tests; each
  row's `expandPattern row corpusRange` is byte-identical to an
  inline expected list.
- **Generated graph shape.** Pinned in 6.A.2 tests; each row's
  compiled `TemplateGraph` is asserted against its §4.B kernel
  hypothesis.
- **Survey recognition (layer (b)).** Lands as the `--corpus-survey`
  subcommand ([MetaSonic.App.CorpusSurvey](app/MetaSonic/App/CorpusSurvey.hs)).
  Runs the corpus rows through the §4 survey machinery and
  reports per-row kernel coverage, corpus-wide kernel totals,
  claimed / missed sink shapes, and §4.D edge-rate opportunity
  contribution. The baseline run is recorded in
  [notes/2026-05-10-phase-6a3-corpus-survey-baseline.md](notes/2026-05-10-phase-6a3-corpus-survey-baseline.md);
  future runs compare against it. A follow-up `spectral-freeze-pad`
  row connects the pattern corpus to §6.D's first spectral kind
  without changing the pattern-driver contract.

Live scheduling polish, ergonomic API, and concert-grade event
timing all stay out of 6.A. Piping the corpus through
`--worker-bench` and a pattern-driven `--swap-bench` is a future
6.A.3 extension if the §4.E / §5 signals warrant it; the current
`--corpus-survey` does not perform those measurements.

### Phase 6.B — OSC Control Surface (closed at contract level)

OSC is the first real external producer. Receive surface only —
binds a configured UDP port, parses single messages, and writes
through the existing realtime control queue. Address space mirrors
6.A's symbolic identifiers (`/<voice-key>/<node-tag>/<slot>`), and
the address-to-target resolution table is the §5.4.C producer-side
mapping work made concrete: if 6.B implementation surfaces
hot-swap re-resolution or multi-producer friction, §5.4.C lands
here.

Departs from §3 MIDI in one deliberate way: OSC parsing and
dispatch live on the Haskell side, not C++. Reasoning is in the
design note. OSC is a control plane, not a data plane; the
realtime control queue decouples the audio callback from
producer-side jitter (events may arrive late under a GC pause,
but the audio thread does not stall).

#### [x] 6.B.1 Design note

Bounds the architecture, scope, and address resolution model
before code lands. Settles the Haskell-vs-C++ ownership decision,
names the §5.4.C connection, and previews the
`MetaSonic.OSC.{Wire,Dispatch}` module shape that 6.B.2 will
implement.

Note: [Phase 6.B OSC design](notes/2026-05-10-phase-6b-osc-design.md).

#### [x] 6.B.2a Wire and dispatch (pure)

`MetaSonic.OSC.Wire` (pure parser + `OscMessage` ADT) and
`MetaSonic.OSC.Dispatch` (pure resolver, `ResolveState`,
`DispatchAction`, `DispatchIssue`). No `IO`, no sockets. v1
grammar is **control writes only**
(`/<voice-key>/<node-tag>/<slot>`); voice lifecycle and
hot-swap stay deferred until argument typing supports a clean
`VoiceOnSpec` encoding. Identifiers used as path segments must
match an OSC-safe profile (`[A-Za-z0-9_-]+`, ≤16 bytes,
reserved words excluded); the dispatch layer validates at
registration time. Tests cover parse round-trip + dispatch
resolution against the 6.A corpus plus negative cases
mirroring 6.A's `DriverIssue` shape (unknown voice / node tag
/ slot, identifier-profile violations).

#### [x] 6.B.2b Bracketed UDP listener

`MetaSonic.OSC.Listen` (in `src/`, not `app/`, so tests can
import it). Exposes a bracketed listener that takes a supplied
`RTGraph`, an `IORef ResolveState`, and a UDP port; binds the
socket, runs the listener thread, and tears down cleanly on
exit. The caller owns the runtime handle and the resolve-state
ref; the listener only reads them and writes through the
existing realtime queue helpers.

#### [x] 6.B.3 End-to-end verification

Loopback integration test in `test/Spec.hs`
(`oscEndToEndTests`): builds a tagged graph
(`SinOsc → tagged "outgain" Gain → Out 0`), compiles to a
`TemplateGraph`, loads it with `loadTemplateGraph`, registers
voice key `v0` against the auto-spawned slot, starts
`withOscListenerHooks` (real FFI + thread-synchronisation hook),
sends a UDP packet `/v0/outgain/0 ,f 0.1`, waits for the
listener's FFI call to complete, and asserts the rendered
bus-0 peak amplitude changed from ~0.5 to ~0.1. Proves the
full receive → parse → dispatch → realtime queue → render
path without external OSC tooling or audio hardware.

#### [x] 6.B.4 `--osc-listen` CLI wrapper

[app/MetaSonic/App/Osc.hs](app/MetaSonic/App/Osc.hs) exposes
`runOscListen :: Int -> IO ()` and is wired as
`--osc-listen [PORT]` (default 7000) in [Main.hs](app/Main.hs).
Loads a built-in demo graph
(`SinOsc 440 Hz → tagged "outgain" Gain → Out 0`), starts
realtime audio, registers voice `v0` against the auto-spawned
slot, and runs the listener until Enter. OSC drops are logged
to stderr. Same demo graph as the §6.B.3 end-to-end test so
the CLI exercises the verified path.

### Phase 6.C — Buffer I/O (closed through §6.C.5)

Buffer I/O is where resource identity becomes real: large sample data,
shared references, mutation / recording, ownership across hot-swap,
allocation rules. Deserves its own design note before any
implementation. Couples to Phase 6.E (most plugin formats want
sample-buffer access), so 6.E may force a 6.C revision rather than
only consume it as-is.

#### [x] 6.C.1 Design note

Bounds 6.C before any contract or code. v1 surface is a
producer-allocated `Buffer` resource with an integer ID
(allocated in `IO` outside `SynthM`), audio-thread-readable
through a new `KPlayBufMono` kind. Settled choices:
mono-per-ID, `float32`, fixed-cap pool, linear interpolation,
two-step allocate + load. `Eff`'s existing `BufRead` /
`BufWrite` constructors get wired to the new kind via
`inferEff`. `busFootprint`-driven template precedence remains
bus-only in v1 — correct for read-only buffers; extending to
buffers is a 6.C.4 concern, gated on a real `BufWrite` UGen.
6.C.3 is split into 6.C.3a (read path) and 6.C.3b (live-safe
retire/free).

Note: [Phase 6.C buffer I/O design](notes/2026-05-10-phase-6c-buffer-io-design.md).

#### [x] 6.C.2 Contract

Pins the v1 surface 6.C.3a implements. Haskell:
`MetaSonic.Bridge.Buffer` exposes a `Buffer` newtype handle,
`allocBuffer` / `loadBuffer` / `clearBuffer` (producer-side
`IO` against an `RTGraph`), and a `BufferIssue` ADT. Source
DSL adds `PlayBufMono` (`UGen`) and `playBufMono` (builder),
with a `KPlayBufMono` `NodeKind` (tag 20, `KindSpec 20
SampleRate 3 4 "playBufMono"`), control vector
`[buffer_id, rate, start_frame, loop_flag]`, and an
`inferEff (PlayBufMono buf _ _ _) = [BufRead (bufferId buf)]`
case. C ABI adds `rt_graph_buffer_alloc` /
`_load_f32` / `_clear` (the last is stopped-audio-only —
live-safe retire/collect lands in 6.C.3b) plus
`rt_graph_test_buffer_read_count` /
`_invalid_read_count` test surfaces. `MAX_BUFFERS = 64`. No
pattern / OSC coupling in v1.

Note: [Phase 6.C.2 buffer I/O contract](notes/2026-05-10-phase-6c2-buffer-io-contract.md).

#### [x] 6.C.3a Resident mono buffer read

Implementation of the v1 read path. `Buffer` newtype in
[Types.hs](src/MetaSonic/Types.hs); `KPlayBufMono` (tag 20,
`KindSpec 20 SampleRate 3 4 "playBufMono"`) with audio inputs
`[rate, start_frame, loop_flag]` and a `PortIgnored` row for
`start_frame` (consumed once at instance reset). Wrapper
module
[MetaSonic.Bridge.Buffer](src/MetaSonic/Bridge/Buffer.hs)
exposes `allocBuffer` / `loadBuffer` / `clearBuffer` against
the new C ABI (`rt_graph_buffer_alloc`,
`rt_graph_buffer_load_f32`, `rt_graph_buffer_clear`) with
exception-throwing `BufferIssue` errors (revised after review:
`BiFrameCountExceedsBuffer` carries only the requested count
since capacity is not exposed across the FFI in v1; a separate
`BiInvalidFrameCount` covers the wrapper-side check that fires
before `fromIntegral` crosses the FFI). Fixed-cap pool of 64
`BufferSlot`s — initially on `RTGraphState` in 6.C.3a, relocated
to the `RTGraph` handle in 6.C.3b slice 1 so the pool survives
hot-swap; counters (`rt_graph_test_buffer_read_count` /
`_invalid_read_count`) tick per sample. Linear-interpolating
`process_play_buf_mono` kernel reads from `st->buffer_id`,
which is resolved from `controls[0]` once at instance reset
and frozen on `PlayBufMonoState` (the §6.C.2 contract;
verified by a live-set_control regression test that swaps a
control write under a running kernel and asserts the playback
buffer does not flip). Invalid / unallocated / cleared IDs
emit zeros and increment the invalid-read counter. End-to-end
test loads a 256-sample sine table, plays it forward, asserts
both the sample-match within `1.0e-5` tolerance and a non-zero
read counter (counter-confirmed validation). Focused kernel
coverage for `start_frame` seeding, loop wrap, one-shot
boundary, fractional-rate / linear interpolation, and
negative-rate clamp — each scenario pins exact valid /
invalid read totals so a regression that emits zeros via a
different code path cannot pass silently. 18 new tests in
`bufferPoolTests` + `playBufMonoTests` — 544 total.

#### [x] 6.C.3b Lifetime hardening

Resource-lifetime hardening step the later phases will lean on.
Shipped in two slices:

1. **[x] Buffer pool relocated to the `RTGraph` handle.** The
   pool + the two per-block read counters moved out of
   `RTGraphState` so a `prepare_swap` / `publish_swap` cycle
   no longer retires buffers with the old world. The kernel
   and all five C ABI entry points reach the pool through
   `g.buffers[...]` instead of `world(g).buffers[...]`.
   `rt_graph_clear` also no longer wipes the pool, since the
   pool is now keyed off the handle. New tests:
   "buffer pool survives c_rt_graph_clear" and
   "buffer pool survives prepare_swap / publish_swap"
   (counter-confirmed via the handle-scoped read counters).
2. **[x] Live-safe `retireBuffer` / `collectRetiredBuffer`.**
   Slot state machine became tristate (`Unallocated`,
   `Allocated`, `Retired`) backed by
   `std::atomic<BufferSlotState>` with release-store on
   write and acquire-load in the kernel. A new
   `buffer_retire_generation` atomic on `RTGraph` ticks at
   the top of every `process_graph`; `retire_buffer` stamps
   the current value on the slot, and `collect_retired`
   returns `-2` ("still live") until the counter advances
   past the snapshot. `clearBuffer` stays stopped-audio-only
   and now refuses to clear `Retired` slots. New
   `BufferIssue` constructors `BiNotRetired` and
   `BiCollectStillLive`. New tests:
   "retire / collect lifecycle reclaims a slot live-safely"
   (the canonical retire-mid-render → render → collect →
   realloc sequence, counter-confirmed), plus negative-path
   coverage for collect-without-retire and clear-after-retire.

C ABI additions: `rt_graph_buffer_retire`,
`rt_graph_buffer_collect_retired`. Haskell wrappers:
`retireBuffer`, `collectRetiredBuffer`. 549 tests total (5 new
since 6.C.3a).

Not done in 6.C.3b: `BufWrite`, file I/O, multichannel, async
load, pattern / OSC coupling for retire. The next thing 6.C
needs is not a writer kind directly — it's the resource-ordering
layer that a writer kind would require, lifted up to a
generalized `ResourceFootprint`. That work opens as 6.C.4.

Note: [Phase 6.C.3b lifetime design](notes/2026-05-11-phase-6c3b-lifetime-design.md).

#### [x] 6.C.4 Buffer resource ordering

Resource-ordering preflight for the writer UGen. Pre-§6.C.4
template / region precedence flowed through `BusFootprint`; once
a writer kind exists, `BusFootprint` is too narrow. 6.C.4
widened the precedence surface to a `ResourceFootprint`
covering both bus and buffer reads / writes / delayed reads
without semantic change for bus-only corpora. Four slices:

1. **[x] Add `BufferFootprint` and `ResourceFootprint`** in
   `Compile.Types` (commit 76fac6b). Type-only; no call site
   touches them.
2. **[x] Pivot `Template.tplFootprint` / `RuntimeRegion.rrFootprint`
   to `ResourceFootprint`** (commit 3fcfdee). New
   `resourceFootprint` / `runtimeNodeResourceFootprint` /
   `regionResourceFootprint` extractors; existing bus-only
   consumers project through `rfBuses`. Bus-only graphs stay
   bit-identical.
3. **[x] Union bus + buffer edges in the precedence rule**
   (commits 05211f6 + 1bd2fd4). New `templatePrecedes`
   consults both intersections (bus-write/bus-read and
   buffer-write/buffer-read). At the region scope the union
   is exposed through a new `regionResourcePrecedence`;
   `regionBusPrecedence` stays bus-only and is the
   diagnostic projection that callers reach for when they
   specifically want to see the bus edge subgraph alone.
   `regionDependencies` (the scheduler's full "must precede"
   view) is the union of `regionResourcePrecedence` and
   `regionStructuralPrecedence`. Bus and buffer id spaces are
   disjoint, so the two halves can never collide. Tests cover
   `BufWrite → BufRead` on same buffer (asymmetric edge),
   `BufWrite` on different buffer (no edge), `BufRead` alone
   (non-ordering), the disjoint-id-space regression guard,
   and an extractor pin that `playBufMono` actually populates
   `bfBufReads` end-to-end through `resourceFootprint` /
   `runtimeNodeResourceFootprint`.
4. **[x] Reject same-buffer `BufWrite / BufWrite`** (commit
   1a363b5). New stage 2.5 in `compileTemplateGraph(Fused)`
   (`checkNoSharedBufferWriters`) fails the compile if any
   buffer id is written by two or more templates, naming both
   the offending buffer and the template names.

`computePrecedence`, `templatePrecedes`, and
`checkNoSharedBufferWriters` are exported from
`Bridge.Templates` so the rule can be exercised against
hand-built `Template` / `ResourceFootprint` values without
needing a writer UGen in the DSL yet.

Same-buffer `BufWrite / BufWrite` lifting is reserved for
6.C.5+ once a real use case forces a pinned ordering
primitive.

After 6.C.4, the writer UGen (`RecordBufMono`) is a separate
follow-up that only has to pin `inferEff (RecordBufMono buf
_ _) = [BufWrite (bufferId buf)]` and ship the kernel — the
ordering machinery picks it up automatically.

558 tests total (9 new since 6.C.3b).

Notes:
- [Phase 6.C.4 resource-ordering design](notes/2026-05-11-phase-6c4-resource-ordering-design.md)
- [Minimal RecordBufMono contract](notes/2026-05-11-record-buf-mono-design.md) — design for the first audio-thread writer (shipped in the 6.C.4 follow-up below).

#### [x] 6.C.4 follow-up — minimal `RecordBufMono`

First audio-thread writer kind. Shipped in three slices, each
keeping `stack test` green:

1. **[x] Haskell surface + green C++ skeleton** (commit
   39539bb). `KRecordBufMono` (tag 21), `kindSpec` /
   `ugenView` / `inferEff` / `dependencies` / `portInfo`
   rows, `recordBufMono` builder. `Bridge.Validate.busEdges`
   pairs `BufWrite` / `BufRead` at the intra-graph scope;
   `runtimeNodeResourceFootprint` learns the writer case.
   C++ side adds `NodeKind::RecordBufMono`, the kind_from_tag
   entry, `RecordBufMonoState { int buffer_id; long long
   write_head; }`, the `configure_spec` row matching the
   Haskell `KindSpec`, and `init_node_state` freezes
   `controls[0]` onto state. New counters
   `buffer_write_count` / `buffer_invalid_write_count` on
   `RTGraph` with the two `rt_graph_test_buffer_*_write_count`
   accessors. Kernel body is a stub that pass-throughs
   `signal_in` and ticks the invalid counter unconditionally;
   real write path is slice 2.
2. **[x] Real `process_record_buf_mono` kernel + writer-band
   barrier** (commit 2448d33). Acquire-load on `slot.state`
   synchronises with `rt_graph_buffer_retire` / `_alloc`;
   one-shot vs. loop branch at the end-of-buffer boundary;
   `buffer_write_count` ticks per valid sample,
   `buffer_invalid_write_count` ticks per
   Retired / Unallocated / past-the-end sample. Pass-through
   audio output is unconditional. New
   `regionHasBufferWriter` / `isBufferWriterKind` predicates
   in `Compile.Dependencies` mirror the existing live-bus
   pair; `Compile.Schedule.regionsToSegments` emits a
   `Barrier` for any region containing a writer, so the
   conservative serialization keeps writer kernels off the
   parallel-band path.
3. **[x] End-to-end test battery** (commit 61674e5).
   record-then-playback within one block (precedence union
   topo-sort, counter-confirmed both sides);
   retire-during-write → collect re-arms (counter delta
   across all three blocks); loop wrap (write head crosses
   the end three times); one-shot stop (valid + invalid
   split exactly); frozen-buffer-id regression mirroring the
   §6.C.2 `PlayBufMono` pin; cross-template same-buffer
   rejection end-to-end via the DSL; scheduler test that
   walks `segmentByBarrier` and asserts the writer region
   appears in a `Barrier`, never a `FreeSegment`.

Out of scope: random-access `BufWr`, multichannel, file I/O,
`start_frame` / `record_run` / `loop_count` controls. The
design note records the Q-1..Q-5 deferrals.

571 tests total (10 new since 6.C.4).

#### [x] 6.C.5 — Writer cardinality hardening

Closes the gap that §6.C.4's cross-template rule left open at
runtime: a single writer template could still spawn N live
instances under the default polyphony cap (8), all frozen to
the same buffer id at instance reset, with slot order silently
deciding the per-block winner.

In v1, a buffer writer is a **single-writer, single-template-
instance resource**. Lifting that constraint is a §6.C.5+
feature and only makes sense once an explicit ordering /
mixdown primitive is designed; the implicit input-order
"ordering" §6.C.4 declined to pin would still be a problem.

1. **[x] Auto-monophonic writer templates** (commit d4f8d54).
   `loadTemplateGraph` / `loadTemplateGraphFused` inspect
   `tplFootprint.rfBuffers.bfBufWrites`; templates whose
   writer set is non-empty are clamped to polyphony = 1 via
   `c_rt_graph_template_set_polyphony` before the auto-spawn.
   Tests: writer template auto-spawn succeeds + second
   `instance_add` returns -1; non-writer template still allows
   multiple instances; clamp survives non-first registration
   position.
2. **[x] Intra-graph duplicate-writer rejection** (commit
   22ffbe8). `validateAndSort` runs a new
   `checkUniqueBufferWriters` pass that fails lowering with a
   diagnostic naming the offending buffer id and contesting
   nodes. Aligns the intra-graph case with the §6.C.4 inter-
   template case; writer + reader on the same buffer still
   composes through E_r. Tests: duplicate writers reject;
   different-buffer writers compose; writer + reader composes.
3. **[x] Docs / roadmap sync** (commit a0dee32). `rt_graph.h`'s
   inter-template precedence comment now spells out the
   bus+buffer rule and the §6.C.5 single-writer-single-
   instance contract; ROADMAP no longer calls the
   `RecordBufMono` note "next implementation series".

##### 6.C.5 follow-up — close the runtime escape hatches

Review of the three commits above turned up two gaps: the
Haskell single-template loaders (`loadRuntimeGraph` /
`loadRuntimeGraphFused`) did not call the clamp, and the public
C ABI (`rt_graph_template_add_node`, `rt_graph_template_set_-
polyphony`, the `rt_graph_add_node` template-0 shim) accepted
the default cap of 8 even for templates carrying a writer node.
A direct-C-ABI caller could still spawn N live writer instances.

1. **[x] C++ runtime backstop** (commit 787a4d9).
   `rt_graph_template_add_node` clamps the cap to 1 in place
   when a `RecordBufMono` kind is added;
   `rt_graph_template_set_polyphony` refuses to raise the cap
   above 1 once a writer is present. Two-sided because callers
   may set the cap and add the node in either order. Documented
   as Note [§6.C.5 single-writer-single-instance invariant] in
   `rt_graph.cpp`. Five new doctest cases cover the four
   direct-ABI paths plus a non-writer baseline.
2. **[x] Haskell single-template loader clamp** (commit f0e152e).
   Adds `clampWriterPolyphonyRG` (RuntimeGraph variant) and
   calls it from both `loadRuntimeGraph` and `loadRuntimeGraph-
   Fused` right after `c_rt_graph_clear`. Three new tests pin
   the loader-side clamp for both fused and unfused paths and
   confirm non-writer graphs keep the default cap.
3. **[x] Docs sync** (this commit). `rt_graph.h`'s
   `rt_graph_template_set_polyphony` /
   `rt_graph_template_add_node` doc comments now describe the
   §6.C.5 backstop in place. The inter-template precedence
   comment cross-references both the Haskell-loader clamp and
   the runtime backstop so the doc names every layer that
   enforces the invariant.

580 Haskell tests, 308 standalone C++ tests (14 new since the
6.C.4 follow-up: 9 Haskell + 5 C++).

### Phase 6.D — Spectral Processing

New `NodeKind` family for streaming DFT (vocoder, spectral freeze,
convolution). FFT windows are inherently block-structured, so 6.D may
*inform* §4.D's block-rate executor rather than only wait on it — the
6.D corpus would be the first non-trivial block-rate consumer the
project sees. Bidirectional coupling: §4.D's executor waits on signal,
and 6.D produces signal.

Landed initial kind:
- [Phase 6.D minimal-spectral-kind design](notes/2026-05-11-phase-6d-spectral-design.md)
  — bounds the first kind (`KSpectralFreeze`, tag 22, N=1024 / hop=256,
  Hann window, freeze gate), pins per-instance window ownership,
  declares N-sample latency through a new `kindLatency` accessor,
  and keeps the runtime resource model unchanged (`inferEff = [Pure]`).
  The first implementation series landed the Haskell surface, real
  overlap-add STFT kernel, spectral-region Barrier classification,
  freeze-mode behavior, hop-boundary latch tests, and runtime-doc
  hardening.

Open follow-up queue:

1. [x] Add a corpus / survey row that exercises `KSpectralFreeze`.
2. [x] Add a descriptive latency-footprint view over compiled graphs.
3. [x] Use that view to report uncompensated parallel-path latency skew.
4. [x] Decide from corpus evidence whether the next runtime slice is
   latency compensation or a second spectral kind. Decision:
   compensation stays parked because the real corpus reports declared
   latency but no uncompensated skew; see
   [Phase 6.D latency follow-up decision](notes/2026-05-11-phase-6d-latency-followup-decision.md).
5. [x] Surface the declared-latency footprint in `--fusion-survey`
   output (parity with `--corpus-survey`'s per-row view), plus a
   `shape/spectral-freeze-tail` shape probe so the corpus-wide
   aggregate has a non-empty number to report. Mirrors the
   `--fusion-survey` `printEdgeRateDistribution` section.
6. Keep block-rate promotion, spectrum-stream types, multichannel
   STFT, variable N / hop, and plugin hosting parked until the
   smaller spectral and latency slices make their requirements
   concrete.

Next 6.D implementation direction: write a small contract note for a
second fixed-size spectral kind (likely a frequency-domain filter
variant such as `KSpectralLpf`) before adding runtime code.

### Phase 6.E — Plugin Hosting

Last because it imports external lifecycles, error vocabularies,
resource ownership rules, and realtime guarantees all at once.
Prerequisites — stable resource model, error vocabulary, audio-thread
guarantees — only become concrete once 6.A–6.D have stressed them.
Coupling to 6.C is real (sample-buffer access) and may force 6.C and
6.E to be co-designed even if 6.E lands later.

Design / implementation note:
- [Phase 6.E plugin-hosting design](notes/2026-05-11-phase-6e-plugin-hosting-design.md)
  — bounds the first kind (`KStaticPlugin`, tag 23) as a fixed
  `Identity`-profile static shim: two audio inputs, one audio output,
  one frozen `plugin_id` metadata control, zero plugin parameters,
  zero declared latency, and `[Pure]` effects. It deliberately does
  not claim per-plugin arity / latency / resource effects on the
  current kind-level metadata model. Slice 1 added the registry,
  Haskell/C++ kind surface, and the deterministic silence skeleton.
  Slice 2 turned on real `Identity` dispatch through the
  `PluginSpec::process` vtable, plus `plugin_call_count` and
  `invalid_plugin_call_count` audio-thread counters with C ABI test
  accessors (`rt_graph_test_plugin_call_count` /
  `rt_graph_test_invalid_plugin_call_count`); the Haskell side's
  `staticPluginSkeletonTests` now asserts non-silent output, per-block
  counter math, and bit-identical samples against a hand-rolled
  `add` graph. Q-deferrals cover max-state size, hot-swap
  migration, error-as-scheduler-signal, parameter layout /
  modulation, cross-template ordering, and name stability.

### [x] Phase 6.E.3 — Plugin metadata follow-up decision

Slice 3 is a decision artifact, not new runtime code. With real
`Identity` dispatch landed, the next plugin kind cannot reuse the
fixed-`Identity` shortcut: per-plugin arity, declared latency, and
resource effects (`BusRead` / `BusWrite` / `BufRead` / `BufWrite`)
all need to flow into the existing compiler-side machinery —
`kindSpec`, `kindLatency`, `inferEff`, `ResourceFootprint`, and
template precedence — without breaking the kind-level
table-shaped sites that adding-a-new-kind currently touches.

Decision note:
- [Phase 6.E.3 plugin metadata decision](notes/2026-05-11-phase-6e3-plugin-metadata-decision.md)
  — chooses a Haskell-side per-plugin metadata table while keeping
  `KStaticPlugin` as the only plugin `NodeKind` for now.

Three shapes were considered:

- **Chosen: per-plugin metadata table on the Haskell side.** Keep
  `KStaticPlugin` as the only plugin `NodeKind`; add a
  Haskell-side catalog that pairs each registered `PluginRef`
  with arity / latency / resource declarations and feeds those
  into `inferEff` / `kindLatency` / `ResourceFootprint` lookups.
  Pro: one kind, one C++ dispatch path, no `NodeKind` growth.
  Con: `kindSpec` / `kindLatency` / port-info code paths grow a
  ref-keyed branch, and `inferEff` becomes per-`UGen` data-
  dependent rather than per-kind.

- **One `NodeKind` per plugin profile.** Add `KDelayPlugin` /
  `KFilterPlugin` / etc. as the second / third plugin kinds.
  Pro: every existing kind-level table-shaped site keeps its
  current shape; arity, latency, and effects stay derivable from
  `kindSpec`-style rows. Con: every new plugin profile costs the
  6-site checklist plus a C++ dispatch case, and the static-vs-
  ABI plugin distinction blurs.

- **Larger `RuntimeNode` metadata extension.** Pull arity /
  latency / effects off `NodeKind` and onto a node-level
  `RuntimeNode` annotation that the compiler computes once and
  ships across the FFI. Pro: dissolves the per-kind /
  per-`PluginRef` split entirely; the same machinery serves
  generated-fusion programs (§7) and authoring-DSL ensembles
  (§8). Con: largest scope, touches the IR and the C ABI, and
  re-shapes survey / inspector code that currently keys on
  `NodeKind`.

The decision-note deliverable is done; the immediate follow-up is the
small Haskell catalog scaffold for the existing `identity` row.

Follow-up scaffold: `MetaSonic.Bridge.Source` now exposes
`StaticPluginInfo`, `staticPluginCatalog`, and `staticPluginInfo`.
The lone `identity` row carries plugin id 0, arity 2 -> 1, zero
declared latency, and `[Pure]` effects; `staticPluginId`, validation,
`ugenView`, and `inferEff` route through that table.

Until a real second plugin (probably a small stateful one such as a one-tap
delay) demands it, broader plugin-host work stays parked. Out-of-scope
for 6.E.3 specifically: LV2 / VST3 / CLAP adapter kinds, dynamic
loading / plugin discovery, plugin-owned UI, MIDI-in plugins, and any
new C ABI surface. Those reopen only after the metadata shape has been
exercised by a second static plugin.

State snapshot at the 6.A–6.D boundary:
- [Phase 6.A–6.D state snapshot](notes/2026-05-11-state-snapshot-phase-6-complete.md).

---

## Phase 7 — Compiler-Generated Fusion and Cost Model

Phase 7 is the follow-up to Phase 4's fusion substrate. Phase 4 made
regions real, added hand-written region kernels, proved scalar
`RFused` chain rewrites, and established the corpus -> survey -> bench
-> equivalence discipline. Phase 7 asks a different question: when can
the Haskell compiler generate fused execution programs for arbitrary
legal regions, and when is doing so measurably worth it?

This phase is deliberately evidence-first. It should not start by
adding a clever runtime backend. The first slice is tooling that can
generate graph families, benchmark paired execution variants, prove
equivalence where possible, and produce a cost model that the future
fusion planner can consume.

Design notes:
- [Phase 7 generated-fusion plan](notes/2026-05-11-phase-7-generated-fusion-plan.md)
  — describes the missing pieces: first-class fusion IR, legality
  model, profitability model, runtime program ABI, survey diagnostics,
  and staged generated-executor rollout.
- [Phase 7.A fusion cost lab design](notes/2026-05-11-phase-7a-fusion-cost-lab-design.md)
  — scopes the first tool: parametric graph generation, paired
  benchmarks, equivalence gates, feature extraction, JSONL/CSV output,
  and explainable cost-model summaries.

### Phase 7.A — Fusion Cost Lab

First slice landed: an offline, non-audio measurement tool beside
`--fusion-survey`, `--worker-bench`, `--swap-bench`, and
`--corpus-survey`.

Initial command shape:

```text
metasonic-bridge --fusion-cost-lab
```

The tool should combine three inputs:

1. real corpus rows from demos, pattern corpus, and survey ensembles;
2. parametric generated families such as sink-terminal chains,
   return tails, fanout near-misses, and block-latched modulation;
3. random/fuzz graphs for legality and equivalence stress.

For each row it should compile and time paired variants:

- stripped node-loop baseline;
- normal hand-written region-kernel path;
- `RFused` path;
- future generated-fusion path once it exists.

Rows are machine-readable first: JSONL by default, with a `--summary`
table for human inspection. Slice 1 emits graph family/member,
runtime variant, node/region/kernel/RFused counts, exact-equivalence
status, ns/sample, and speedup against a stripped node-loop baseline.
The follow-up feature slice added a small demo/pattern corpus family
plus resource-footprint, declared-latency, and consumer/fanout columns.
A snapshot-checker slice added `--snapshot-check`, which asserts
cost-lab row/equivalence/feature invariants and survey corpus
compile/latency/shape invariants without comparing full text output.
Open follow-up fields are counter summary, spread, random/fuzz rows,
and the future generated-fusion variant.

Goal: produce measured rules such as "sink-terminal 3+ node chains are
profitable" or "buffer-terminal filter chains are borderline" instead
of treating fusion as a theoretical optimization.

### Phase 7.B — Fusion Legality and Capability Metadata

Add compiler-visible metadata that classifies each `NodeKind` for
fusion planning:

- pure sample operation;
- stateful sample operation;
- sink terminal;
- resource reader/writer;
- latency-bearing node;
- hard barrier.

The output is not a runtime change. It is the legality vocabulary the
planner and cost lab share.

### Phase 7.C — FusionProgram IR and Survey-Only Planner

Introduce a first-class Haskell representation for generated fused
programs. The initial planner should build and pretty-print candidate
programs, then report why each candidate is accepted or rejected.

No C++ executor is required in this slice. The important output is
diagnostic: candidate shape, member nodes, effects, latency footprint,
estimated benefit, and rejection reason.

### Phase 7.D — Runtime Program ABI and Tiny Executor

Only after the cost lab and survey-only planner exist, add a runtime
program table and a tiny executor for a safe subset:

- scalar read;
- input read;
- add;
- multiply;
- sink write.

This intentionally overlaps with `RFused`; the overlap gives a
low-risk equivalence target before stateful source/filter programs are
attempted.

### Phase 7.E — Generated Equivalents of Current Kernel Shapes

Teach the planner/executor to generate programs equivalent to the
current hand-written sink-terminal kernel families, then compare all
three paths:

- stripped node-loop baseline;
- hand-written region kernel;
- generated fusion program.

The hand-written kernels stay as references and may remain fast paths
where they beat the generated executor.

### Phase 7.F — Profitability Gate and Turn-On Decision

Generated fusion should become default behavior only when the planner
can explain both legality and measured benefit. The decision should be
driven by the cost lab and real corpus signal, not by the existence of
a backend.

Possible planner decisions:

- fuse;
- do not fuse;
- illegal;
- needs benchmark data.

Until this gate exists, generated fusion remains opt-in.

---

## Phase 8 — Authoring DSL and Composition Layer

Phase 8 is the user-facing counterpart to the compiler/runtime work in
Phases 4-7. The low-level source DSL is already expressive enough to
build real graphs, but authors still work directly with mono
`Connection`s, explicit repeated branches, explicit output channels,
manual bus numbers, and hand-assembled template lists. Phase 8 should
turn those primitives into a higher-level composition surface without
creating a second compiler.

The boundary is strict:

- Phase 8 elaborates down to ordinary `SynthGraph` and
  `TemplateGraph` values.
- `Source`, `Templates`, `Validate`, `IR`, and `Compile` remain the
  semantic authority.
- All resource ordering, latency metadata, fusion decisions, state
  migration, and runtime loading still flow through the existing
  compiler pipeline.
- The layer is authoring ergonomics plus structured expansion, not new
  runtime behavior.

This phase should be evaluated by whether it makes practical patches
shorter, safer, and easier to inspect while keeping the generated graph
fully transparent to the existing tools.

Design note:
- [Phase 8 authoring DSL design](notes/2026-05-11-phase-8-authoring-dsl-design.md)
  — records the elaboration-only contract, first signal collection
  types, multichannel expansion rules, routing/ensemble/control
  follow-ups, lowering transparency requirements, and first
  implementation series.
- [Session layer scoping gate](notes/2026-05-11-session-layer-scoping.md)
  — records the structural pushback: session/authoring is a next
  product direction, but session runtime implementation waits for a
  Phase 7 planner/cost-model v1 and gets its own ownership scoping.

### [x] Phase 8.A — Authoring DSL Contract

The contract note is landed. It decides:

- which concepts belong in the high-level authoring layer;
- what lowers to one primitive graph vs. multiple templates;
- how generated node names, migration keys, controls, buffers, and
  buses stay stable and inspectable;
- what the layer deliberately does not own.

Non-goals for the first pass:

- a new parser or external language;
- a replacement for `SynthM`;
- type-level modeling of every rate/effect rule;
- bypassing validation or template scheduling;
- hidden runtime allocation.

### [x] Phase 8.B — Signal Collection Types

Introduced lightweight wrappers over existing `Connection`s:

```haskell
newtype Mono = Mono Connection
data Stereo = Stereo Connection Connection
newtype Channels = Channels [Connection]
```

The first helper surface should be boring and explicit:

- `mono`;
- `stereo`;
- `channels`;
- `duplicate`;
- `mapChannels`;
- `zipChannelsWith`;
- `mix`;
- `sumChannels`.

This gives the project multichannel authoring without changing the
runtime audio buffer model.

### Phase 8.C — Lifted UGen Combinators and Multichannel Expansion (partial)

First slice added lifted versions of common primitives that expand
channel-wise:

- gain over mono/stereo/channel sets;
- filter over mono/stereo/channel sets;
- add/mix over compatible channel shapes;
- `outStereo` / `outChannels`;
- deterministic expansion tests that pin the generated primitive graph.

The first implementation should cover only the common musical surface:
gain, add, LPF/HPF/BPF/Notch, delay where safe, and output routing.
More exotic nodes can wait until the shape is needed.

### Phase 8.D — Mixing, Panning, and Routing Helpers (partial)

Add authoring-level operations that remove routine boilerplate:

- `pan2` (landed, constant equal-power pan);
- `balance`;
- `mixN` (landed, list-of-mono mixdown);
- `spread`;
- `send`;
- `returnBus`;
- `stereoOut` (landed as the noun-first `outStereo` alias).

The first helper slice also rewrote the `stereo-saw` demo to use
`pan2`, `addS`, `gainS`, and `stereoOut`, with lowering tests pinning
the primitive Gain/Add/Out graph shape.

The important design point is bus visibility. Helpers may allocate or
thread bus identifiers, but the lowered graph must still expose the
actual bus reads/writes so `BusFootprint`, template ordering, survey
tools, and inspectors remain truthful.

### Phase 8.E — Template and Ensemble Builders

Provide a higher-level way to describe multi-template systems:

```haskell
ensemble $ do
  voice "bass" ...
  voice "pad" ...
  fx "return" ...
```

This should lower to the existing `compileTemplateGraph` input shape,
not replace it. The value of the layer is stable naming, less manual
bus plumbing, and clearer intent around voice templates, shared FX,
and return chains.

### Phase 8.F — Named Controls and External Mapping

Promote named controls as authoring objects rather than incidental
nodes:

- named MIDI CC controls;
- named OSC-addressable controls;
- range/default metadata;
- optional smoothing policy;
- stable post-compile lookup for runtime control binding.

The existing `cc` builder and OSC control surface stay underneath.
Phase 8 should make the control vocabulary easier to write and easier
to inspect.

### Phase 8.G — Lowering Tests, Demos, and Inspector Hooks

Every high-level combinator should have tests that prove what
primitive graph it emits. The first demo rewrite should be small but
real: for example, a stereo detuned patch or a send/return ensemble
that becomes substantially clearer with the new layer.

Inspector and survey output should eventually be able to show both:

- the authoring-level construct;
- the generated primitive nodes/templates/buses.

This prevents the authoring DSL from becoming opaque.

### Session-Layer Scoping Gate (not a numbered phase yet)

The session layer is the likely product direction after authoring and
planner tooling, but it is not a small continuation of Phase 8.D.
It crosses `RTGraph` ownership, producer fan-in, OSC resolve-state
updates on hot-swap, MIDI/pattern coexistence, and buffer/plugin
lifecycle reporting.

Current decision: write and refine the scoping contract now, but do not
start session runtime code until Phase 7 has capability metadata,
survey-only planner output, and a first cost-model table. That places
session implementation after a planner/cost-model v1, but it does not
require waiting for a generated fusion executor to ship.

---

## Design Principles

1. **Haskell compiles, C++ executes.** All graph semantics, rate
   inference, effect analysis, and topological ordering happen before
   the FFI boundary. The C++ runtime is intentionally *as simple as
   possible* at each stage.

2. **Q is DSP substrate, not architecture.** Q is just the starting
   point, it provides oscillators, filters, envelopes, delays,
   smoothing, audio I/O, and MIDI. It does not own graph topology,
   scheduling, or instance management.

3. **Compiled graphs are stronger than SynthDefs.** A MetaDef carries
   execution order, rate annotations, and (eventually) resource-hazard
   metadata. SuperCollider's SynthDef is a template; a MetaDef is a
   template *plus* a proof of safe execution.

4. **No symbolic lookups on the audio thread.** Dense indices,
   pre-resolved order, pre-allocated state. This is already true and
   *must* stay true at every stage.

5. **Compiler-derived ordering beats manual ordering.** SuperCollider
   requires users to manage node order and group structure to avoid
   bus-dependency bugs. MetaSonic can compute safe ordering from
   effect annotations, giving the same flexibility with much *less*
   runtime superstition.

6. **Regions are the scheduling unit, not nodes.** Individual UGens
   are too fine-grained for efficient scheduling. Fusion, SIMD, and
   threading all target regions.
