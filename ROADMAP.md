# MetaSonic Roadmap

MetaSonic compiles rich synth graphs in Haskell and executes them
deterministically in C++. The goal is a system with SuperCollider's expressive
power but stronger ahead-of-time guarantees: graph topology, execution order,
rate propagation, and resource hazards are all resolved at compile time, not
discovered at runtime.

The architecture has three layers:

| Layer                                 | Role                                           | Analog in SC |
|---------------------------------------|------------------------------------------------|--------------|
| **metasonic-core + bridge**           | Create and compile graphs                      | sclang       |
| **Compiled RuntimeGraph/RegionGraph** | Immutable synth template                       | SynthDef     |
| **tinysynth runtime**                 | Instance host, buses, groups, voices, MIDI, UI | scsynth      |

[Cycfi Q](https://github.com/cycfi/q) serves as the **DSP kernel and I/O
substrate** — oscillators, filters, envelopes, delays, smoothing, audio streams,
MIDI. It does _not_ own graph topology; MetaSonic does. MIDI input (via Q's
typed MIDI stack) and UI control surfaces are part of the tinysynth layer: live
event dispatch and voice management stay in C++, while Haskell is responsible
only for compiling structure.

---

# Next Steps

## 0 — Current State (2026-05-09)

A compiled MetaSonic graph builds a subtractive voice
(oscillator → filter → envelope → delay → output), plays it polyphonically
from a MIDI controller, and routes the mix through a shared FX template via
the bus pool. End-to-end demos cover chain, fan-out, saw, noise, filtered
noise, resonant bass, detuned-saw beating, envelope-shaped pluck, vibrato
FM, multi-template send-return, and live-MIDI poly.

What's landed:

- **Phase 1 — node registry.** Eighteen `NodeKind`s implemented:
  oscillators `SinOsc` / `SawOsc` (PolyBLEP) / `PulseOsc` / `TriOsc`,
  `NoiseGen`, biquads `LPF` / `HPF` / `BPF` / `Notch` (Bristow-Johnson via
  Q), arithmetic `Gain` / `Add`, sinks `Out` / `BusOut`, `Env`
  (`q::adsr_envelope_gen`), `Delay` (`q::fractional_ring_buffer`), `Smooth`
  (`q::dynamic_smoother`), `BusIn` / `BusInDelayed`. Per-node state unified
  under `std::variant` with `std::get_if` dispatch. See §1 for per-kind
  status.
- **Phase 2 — instance / multi-template model.** §2.A–§2.E done: spec/state
  split (`MetaDef` + `GraphInstance`), multi-instance support with slot
  reuse, server-global bus pool (single-buffered live, double-buffered
  delayed), multi-template runtime with compile-time inter-template
  precedence derived from `BusFootprint`, release-then-free instance
  lifecycle. §2.F (groups) closed as declined.
- **Phase 3 — polyphony and MIDI.** C++ `VoiceAllocator` over the realtime
  ABI, `MidiVoiceProcessor` translating MIDI 1.0 over Q's typed MIDI stack,
  per-voice CC + pitch-bend through the realtime control queue, `Smooth`
  auto-inserted at control ingress. The `midi-poly` demo plays end-to-end
  from an external controller.
- **Phase 4.A/B/C/D — regions, fused kernels, single-input fusion, rate
  metadata.** Region overlay shipped across the FFI; seven hand-written
  region kernels (six sink-terminal, one buffer-terminal) selected
  unconditionally with longest-match priority; scalar Gain/Add chain fusion
  via the `FAffineFrom` algebra (one scratch slot per fused input);
  IR-propagated `rnRate` plus per-kind/per-port `PortConsumptionRate`
  metadata in place. `Eff` annotations are real for the bus kinds and drive
  both intra-graph E_r ordering and inter-template precedence.
- **Tooling.** Brick TUI inspector (`--inspect` / `--inspect-only`),
  `--fusion-survey` for kernel coverage and rate distribution,
  `tools/rt_graph_bench.cpp` synthetic bench, and `--worker-bench`
  Haskell-loaded worker bench.

Parked / deferred:

- **Sample-accurate connected control inputs.** Currently block-latched from
  sample 0.
- **Block-rate execution path (§4.D).** Per-node output rate is too coarse
  (100 % `SampleRate` on the surveyed corpus); the per-port consumption
  view shows a small but non-zero signal (4 sample-rate producer nodes
  across 4 distinct kinds wired only into block-latched ports). Metadata
  is preserved; the runtime path waits for the signal to grow.
- **Region-level parallelism (§4.E).** Worker-pool Free-band dispatch is
  test-gated and default-off; only targeted probes win. C1d-a region
  work-item metadata is in place but the executor ignores it. C1d-b
  (serial region-item executor) is the next slice.
- **Whole-region kernel codegen.** Deferred indefinitely. Hand-written DSP
  bodies plus narrow helpers (`SinkAccumulator`, `drive_oscillator`) are
  the working approach.
- **Filtered/stateful kernel expansion.** Gated behind survey recurrence +
  benchmark evidence (§4.B.x). Tri/Pulse/Add filtered tails parked as
  singleton-source rows until corpus growth puts them past the gate.

---

## 0.5 — Contract & Foundations

The post-2026-03-25 review (see [Design notes after Miller Puckette][puckette])
flagged that contract drift between the Haskell and C++ sides is already
happening, and that adding more nodes onto an unverified contract compounds
the problem. Phase 0.5 inserts the smallest amount of work that makes
everything after it safer.

[puckette]: ../blog/posts/2026-03-25-design-notes-from-puckette.md

### 0.5.1 Machine-checked kindTag agreement — done

`rt_graph_kind_count()` and `rt_graph_kind_supported(int tag)` are exposed
through the C ABI and a Haskell property test enumerates every `NodeKind`,
computes `kindTag`, and asserts the C++ side recognises that integer.

### 0.5.2 Stand up the test suite — done

`test/Spec.hs` carries 71 tests: structural unit tests on the demo graphs,
QuickCheck properties on dense lowering and region invariants (indices,
topological order, count preservation, region partitioning, rate / effect
forward-defense), the kindTag-agreement test from 0.5.1, an end-to-end FFI
round-trip, and a per-kind metadata cross-check ([0.5.5](#055-collapse-per-kind-metadata--done)).

### 0.5.3 Resolve `BusOut` / `BusIn` — done

Dropped from `UGen` and the source DSL. Inter-graph shared-bus routing
returns when the Phase 2 instance/server model can back it; until then `UGen`
is total under `ugenView` and contains no constructors that panic.

### 0.5.4 Document the node-add procedure — done

`CLAUDE.md` now lists every site that has to change to add a node kind, in
sibling-form: 5 sites across 2 Haskell files (after the [0.5.5](#055-collapse-per-kind-metadata--done)
refactor) plus the C++ dispatch in `rt_graph.cpp`. The QuickCheck cross-check
in 0.5.2 makes arity drift between the Haskell metadata table and the
constructor view fail at test time.

### 0.5.5 Collapse per-kind metadata — done

Per-kind facts now live in two table-shaped sites on the Haskell side:
`kindSpec` in `Types.hs` (tag, rate, effects, arities, label) and `ugenView`
in `Source.hs` (constructor → kind, inputs, controls). `kindTag`,
`inferRate`, `inferEff`, `inferKind`, `lowerInputs`, `extractControls`, and
`dependencies` are all derivations — no per-kind clauses. Adding a kind went
from 10 sites in 3 files to 5 sites in 2 files, with a property test pinning
the two tables together.

---

## 1 — Node Registry (trimmed)

The original Phase 1 listed seven items so the system could describe a full
subtractive voice. The current scope is narrower: **add only the nodes that
make Phase 2 (instance model) testable.** Variations on existing kernels
(more oscillator waveforms, more biquad modes) are deferred — they're low-risk
and can land at any later point.

### 1.1 Replace `SinOsc` internals with `q::sin_osc`  — done

`process_sinosc` uses `q::phase_iterator` for phase accumulation and `q::sin`
(lookup-table) for waveform generation. Phase state lives in `OscState` via
`std::variant`.

### 1.2 Bandlimited oscillators  — done

`SawOsc` (PolyBLEP via `q::saw`), `PulseOsc` (with audio-rate width), and
`TriOsc` are implemented. All three share the `OscState` `std::variant`
slot and reconfigure-on-change for control parameters.

### 1.3 Biquad filter family  — substantively done

`LPF`, `HPF`, `BPF`, and `Notch` are implemented as separate `NodeKind`s
sharing a `q::biquad`-shaped `LPFState`-style slot, each with
reconfigure-on-change semantics. Peaking and shelf modes are deferred —
they're additional rows in the same kernel family and add no new
contract surface.

### 1.4 Envelope generator  — done

Wraps `q::adsr_envelope_gen` as `KEnv` (tag 9). One audio input (gate, with
sample-accurate edge detection at threshold 0.5 → `attack()` / `release()`)
and five controls `[gate_default, A, D, S, R]`. A/D/R are durations in
seconds, S is a linear amplitude in [0, 1]; sustain *rate* is held at the q
default of 50 s (slow background fade during sustained gate-on).

The kernel uses the same reconfigure-on-change discipline as LPF: A/D/S/R
changes update the q ramp segments at block boundaries, the envelope_gen is
constructed lazily on first process() against the active sample rate, and
the envelope state machine (idle / attack / decay / sustain / release) lives
inside `EnvState`. This is the first node with non-trivial lifecycle state,
so it doubles as the shakedown for whether the per-node `std::variant` model
survives the Phase 2 instance split — without changes, it does.

`Bridge.Source.env` is the user-facing builder; `app/Main.hs:envPluckGraph`
demonstrates `Env` shaping a sine into a percussive pluck. End-to-end FFI
tests assert attack-then-sustain behaviour on a held gate and silence on an
idle gate.

### 1.5 Delay line  — done

`KDelay` (tag 8) wraps `q::fractional_ring_buffer` for sub-sample
interpolation. One audio input (signal) and three controls
`[delay_seconds, feedback, mix]`; per-node state lives in `DelayState`. The
buffer is sized at template compile time from a max-delay default and reused
across instances of the template via the spec/state split.

### 1.6 Bus-routing kinds (`BusOut` / `BusIn` / `BusInDelayed`)  — done in §2

Reinstated alongside the §2.C server-global bus pool. `BusOut` writes a
post-mix into the named bus; `BusIn` reads it live within the same block
(producer must have run earlier in the schedule, enforced by E_r within a
template and by the inter-template precedence DAG across templates);
`BusInDelayed` reads the previous block's value, allowing one-block-bounded
feedback without ordering constraints. The pool is single-buffered for live
reads and double-buffered for delayed reads; the swap happens once per block
at the `Server` level.

### 1.7 `dynamic_smoother` at control ingress  — done in §3.3c

`KSmooth` wraps `q::dynamic_smoother`. The `cc` builder auto-inserts
`Smooth` at control ingress so live MIDI CC writes don't zipper. See
§3.3c for the integration with the per-voice control mapping.

A compiled graph today can describe a subtractive voice with release
behaviour and one effect — oscillator → filter → envelope → delay → output —
play it polyphonically from a MIDI controller (Phase 3), and route the mix
through a shared FX template via the bus pool (see the `send-return` demo).

---

## 2 — MetaDef / GraphInstance Split

Move from "one compiled graph is the whole engine" to "a compiled graph is an
immutable template instantiated many times." Landed in four sub-phases
§2.A–§2.D plus the §2.D send-return demo. Renumbered from the original
§2.1–§2.4 sketch as the work was carved up across commits.

### 2.A Spec / state split  — done

`MetaDef` (immutable, per-template) carries `NodeSpec[]`,
`Connection[]`, and `default_controls`; `GraphInstance` carries
`NodeInstanceState[]` and per-instance control overrides. Phase counters,
filter memory, ADSR position, and delay buffers all live in the instance,
not the spec. This is the load-bearing refactor that makes everything
afterward possible.

### 2.B Multi-instance support  — done

`rt_graph_instance_add` / `_remove` / `_alive` / `_count` plus
per-instance `_set_control` / `_read_bus`. Instances are stored in a
`std::vector<std::optional<GraphInstance>>` with slot reuse (dead slots
are filled before the vector grows), so `instance_id` is dense within the
slot range and stable for the life of the instance. Each instance runs the
same spec with its own kernel state.

### 2.C Server-global buses  — done

The bus pool moved out of the per-instance struct into a `Server` owned by
the runtime. Live-read buses are single-buffered; delayed-read buses are
double-buffered with a swap-and-clear at block boundaries. Pool is shared
across all instances of all templates — there is no per-instance or
per-template scope for bus reads. This is what unlocks `voice → fx`
routing across separate compiled graphs.

### 2.D Multi-template runtime  — done

§2.D.1 fixed `inferEff` so `Out` carries `BusWrite n` (was `Pure`), making
the effect vocabulary honest about hardware-bound output too.

§2.D.2 added [`Bridge/Templates.hs`](../src/MetaSonic/Bridge/Templates.hs):
`compileTemplateGraph :: [(String, SynthGraph)] -> Either String
TemplateGraph` extracts a `BusFootprint` (writes / live-reads /
delayed-reads) per template from `irEffects`, builds a precedence DAG
where `T_a` precedes `T_b` iff `bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅`, and
topo-sorts it. Delayed reads do not contribute, exactly as within a
single graph. Cycles → compile error.

§2.D.3 turned `RTGraph` into a vector of `MetaDef`s with a flat instance
table tagging each `GraphInstance` by `template_id`. `process_graph`
iterates templates in registration (= execution) order, processing every
live instance of each template before advancing. The runtime never
reorders. Legacy single-template entries (`rt_graph_add_node`,
`rt_graph_set_control`, `rt_graph_connect`) are preserved as thin shims
operating on auto-created template 0.

The §2.D demo (`send-return`) wires a saw-with-vibrato voice template
that writes bus 7 and a low-pass FX template that reads bus 7 and writes
hardware bus 0; `compileTemplateGraph` schedules voice before fx without
any user-visible group object.

### 2.E Instance lifecycle: release-then-free  — done

`rt_graph_instance_release` flips a slot to `Releasing`, lets envelopes
complete their tail, and reclaims the slot once the instance produces
silence across a configured threshold + window. Hard-free
(`rt_graph_instance_remove`) remains available for deliberate cuts
(panic stops, voice stealing in extremis). A polyphonic stress test
exercises many voices with staggered release and slot reuse.

### 2.F Groups  — declined

The original §2.4 envisioned SuperCollider-style groups: ordered
containers of instances with intra-group bus-derived ordering.
`TemplateGraph` already derives inter-template ordering from bus
footprints at compile time, and SC's group reparenting is exactly the
runtime ordering knob this design rejects (see Design Principle 5 and
the "Compile-time vs runtime ordering" note in `CLAUDE.md`). Closed
as decided-against. If a concrete use case appears that the static
schedule cannot serve, reopen then.

---

## Phase 3 — Polyphony and MIDI

Real-time voice allocation driven by MIDI input.

### 3.1 Voice allocator  — done

A C++ `VoiceAllocator` over the realtime ABI maps note-on events to
`rt_graph_template_instance_add` (Reserve / Activate via the SPSC queue)
and note-off events to `rt_graph_instance_release` (§2.E). Voice stealing
policy lives here; hard-free is reserved for stealing under pressure.

### 3.2 Q MIDI integration  — done

`MidiVoiceProcessor` is a MIDI-1.0 → `VoiceAllocator` translator built on
Q's typed MIDI stack (`note_on`, `note_off`, CC, pitch-bend, processor
concept, input stream dispatch). Note events stay in C++; Haskell compiles
structure, C++ owns live note lifetimes. Haskell does not send MIDI to
tinysynth, unlike SC3. The Q `q_io` MIDI sources are vendored locally with
two patches.

### 3.3 Per-voice control mapping  — done

3.3a wired per-voice CC + pitch-bend dispatch through the realtime control
queue. 3.3b stabilised the live-MIDI demo lifecycle. 3.3c added `KSmooth`
(`q::dynamic_smoother`) and made the `cc` builder auto-insert it at control
ingress so CC writes don't zipper. The live-MIDI poly demo (`midi-poly`
entry) plays a polyphonic MetaSonic instrument from a MIDI controller,
end-to-end.

---

## Phase 4 — Fusion, Regions, and Rate Propagation

Move scheduling granularity from individual nodes to fused regions, in
two complementary tracks.

**Single-input rewrite fusion (§4.C — done):** a consumer's input
read absorbs a producer's per-block work via the `RFused` algebra,
the producer is elided but remains control-addressable, and one
scratch slot per fused input keeps memory cost bounded. Both
scalar `Gain` (4.C.1) and scalar `Add` / bias (4.C.2) collapse
into the same `FAffineFrom` chain-walk; chains compose end-to-end.

**Region-level execution (§4.A / §4.B / §4.D — done in scope;
§4.E ahead):** §4.A's region overlay and §4.B's hand-written
region kernels are now real, not conceptual. The region-kernel
surface covers buffer-terminal (`RSawLpfGain`) and sink-terminal
(3-node `RSinGainOut` / `RSawGainOut` / `RNoiseGainOut`; 4-node
`RSawLpfGainOut` / `RBusInLpfGainOut` / `RNoiseLpfGainOut`)
shapes. Selection runs unconditionally inside
`compileRuntimeGraph`; longest-match priority handles 3- vs 4-node
overlap. `--fusion-survey` and the microbench under
`tools/rt_graph_bench.cpp` are the evidence infrastructure that
gates kernel additions; the same gate currently parks Tri/Pulse/Add
filtered tails as low-signal singletons.

§4.D landed as descriptive infrastructure. §4.D.1 carried the
IR-propagated `rnRate` into `RuntimeNode` and added a survey
"Rate distribution" section, which reported 100% `SampleRate` on
the corpus and proved per-node /output/ rate is too coarse on its
own to license block-rate regions. §4.D.2 added per-kind / per-port
consumption-rate metadata (`PortInfo` / `PortConsumptionRate` —
`PortBlockLatched` for filter freq/q, `PortIgnored` for oscillator
phase, `PortSampleAccurate` for everything else) and a
producer-grouped opportunity headline. The empirical signal is
small (4 sample-rate producer nodes across 4 distinct kinds in
the surveyed corpus). A runtime block-rate execution path is
parked until that signal grows.

What's in progress: §4.E (region-level parallelism —
independent regions / templates on separate threads). The
schedule metadata, global schedule, deterministic reduction
substrate, test-gated worker Free-band dispatch, synthetic bench,
Haskell-loaded worker bench, and first corpus-evolution probes are
now in place. The current turn-on decision is negative:
worker dispatch remains test/bench gated because the only
Haskell-loaded rows that actually enter worker dispatch are
targeted probes and still lose. The next decision is narrower:
either add less synthetic corpus shapes with enough work to make
worker dispatch plausible, or investigate region-level dispatch
inside one `FreeLayer` step. §4.D's descriptive metadata remains
in place and feeds future scheduling decisions; the block-rate
execution path stays parked until the per-port survey signal grows.

What's deferred indefinitely: whole-region kernel /codegen/.
Hand-written DSP bodies plus narrow helpers (`SinkAccumulator`,
`drive_oscillator`) are the working approach; codegen waits
until that becomes a real maintenance problem, which it is not
today.

### 4.A Region formation — done

`formRegions` produces a contiguous, rate-coherent partition of the
runtime graph; `RuntimeRegion` carries the dense member list,
region rate, and inter-region dependency edges. The runtime ships
the region overlay across the FFI and `process_instance` dispatches
on it. Future work (§4.E) consumes this overlay; codegen does not
(see Phase 4 introduction).

### 4.B Q inside region kernels — done

Hand-written fused kernels run through `process_instance`'s
region dispatch. The current set, with the shape each one claims:

| Kernel              | Arity | Shape                                  | Class         |
|---------------------|-------|----------------------------------------|---------------|
| `RSawLpfGain`       | 3     | `[KSawOsc, KLPF, KGain]`               | buffer-term.  |
| `RSinGainOut`       | 3     | `[KSinOsc, KGain, /sink/]`             | sink-term.    |
| `RSawGainOut`       | 3     | `[KSawOsc, KGain, /sink/]`             | sink-term.    |
| `RNoiseGainOut`     | 3     | `[KNoiseGen, KGain, /sink/]`           | sink-term.    |
| `RSawLpfGainOut`    | 4     | `[KSawOsc, KLPF, KGain, /sink/]`       | sink-term.    |
| `RBusInLpfGainOut`  | 4     | `[KBusIn, KLPF, KGain, /sink/]`        | sink-term.    |
| `RNoiseLpfGainOut`  | 4     | `[KNoiseGen, KLPF, KGain, /sink/]`     | sink-term.    |

`/sink/` is `KOut` or `KBusOut` — both dispatch to the same
sink-absorbing path; the kernel body is bus-kind-agnostic.
Longest-match priority resolves the 3-vs-4 overlap (e.g.
`[Saw, LPF, Gain, Out]` is claimed by `RSawLpfGainOut`, not
`RSawLpfGain` + a trailing per-node `Out`).

Sink-terminal kernels are the proven class: they remove an
extra per-node dispatch /and/ inline the sink's bus
accumulation + `block_sink_peak` update, which is what makes the
fusion measurable. Buffer-terminal is useful but borderline; the
biquad cost dominates the dispatch cost on its own.

`RBusInLpfGainOut` is the first non-oscillator producer kernel —
the source is a bus reader rather than a generator with phase or
PRNG state. It claims the `BusIn → LPF → Gain → /sink/`
return-tail shape that arises naturally in cross-template
send/return ensembles.

`RNoiseLpfGainOut` is the noise counterpart of `RSawLpfGainOut`:
the producer is a `q::white_noise_gen` xorshift PRNG whose state
the kernel pulls one sample at a time, mirroring the per-node
`process_noisegen` cadence (the load-bearing bit-equivalence pin).
It was unparked after the corpus-first → ranked-table → gate →
benchmark loop reached `missed=4, sources=4` and the benchmark
landed at median ~1.25x. Tri/Pulse/Add filtered tails stayed
singleton-source `no-signal` rows in the same scan and remain
parked.

#### 4.B.x Kernel-add gate

Filtered/stateful kernel additions go through a four-clause gate.
This is the discipline that kept `RNoiseLpfGainOut` parked while
the survey signal was 3 missed across 3 graphs (insufficient
sources), and that triggered the unparking once corpus expansion
brought the count to `missed=4, sources=4` in the ranked
missed-shape table. Tri/Pulse/Add stay parked at singleton
sources by the same gate.

1. **Survey recurrence.** The shape recurs across multiple
   distinct topologies in `--fusion-survey`'s ranked missed-shape
   table. Concrete threshold: `missed ≥ 3 ∧ sources ≥ 3`. The
   `sources` column counts distinct `srDemo` strings; multi-
   template ensembles count as one source even if several
   templates contribute the same shape. Single-graph shape probes
   contribute to matcher coverage but not to kernel-add
   justification.
2. **Benchmark threshold.** The fused kernel hits the
   sink-kernel win range (roughly 1.2x–1.9x speedup over the
   stripped node-loop baseline) on `tools/rt_graph_bench.cpp`.
   Smaller wins than `RSawLpfGainOut`'s ~1.3x deserve scrutiny;
   the kernel pays ongoing maintenance cost forever.
3. **Stripped node-loop baseline equivalence.** Bit-equivalence
   tests use `stripRegionKernels` to force per-node dispatch on
   the same compiled graph, then compare bus output sample-for-
   sample against the kernel's render. Anything looser
   (kernel-vs-kernel, approx float compare) is a coverage gap.
4. **Edge-case parity, including invalid-input paths.** The
   kernel handles every per-node baseline behaviour, including
   the cases that nominally look like "no work this block."
   `RBusInLpfGainOut`'s near-miss was exactly this: an early-
   return on invalid `busin.bus` froze the LPF state, which
   then desynchronized from the per-node baseline on the next
   valid block. Stateful filters cannot skip the loop; they must
   advance state on zero input, the same way the per-node
   chain would.

### 4.C Single-input rewrite fusion (RFused algebra)

Per-port rewrites that elide a single-consumer producer node by absorbing
its per-block work into the consumer's input read. The elided node stays
in `rgNodes` with `rnElided = True` so its `NodeIndex` and controls
remain addressable through `set_control` and the realtime control queue;
the runtime reads each control live at fused-input evaluation time, so
chained-fused output is bit-identical to the unfused kernel chain.

#### 4.C.1 Scalar Gain fusion (single-edge + chain) — done

Step C (a-g): `KGain` nodes whose work is to multiply a single-consumer
signal by a control-rate scalar are elided into the consumer's input
through `RFused FScaleFrom` (length 1) or `RFused FScaleChainFrom`
(length ≥ 2, runs of consecutive scalar Gains feeding one non-candidate
sink). The C++ resolver applies each scale in source-to-sink order with
the same `sanitize_finite(float(...), 1.0f)` discipline as
`process_gain`, so float rounding is preserved. One scratch slot per
fused input regardless of chain length. Live behind the demo runner's
`--fused` flag.

#### 4.C.2 Scalar Add / bias fusion — done

Scalar `Add` (one signal input, one `RConst` bias on the other
port) folded into the same chain-walk as scalar Gain. The two
shapes share the heterogeneous `FAffineFrom` chain descriptor:
runs of scalar Gains and scalar Adds in any order — `src → Gain(k)
→ Add(b) → consumer` and reverse — collapse end-to-end into one
fused input with one scratch slot. Audio-rate Adds stay dispatched,
exactly as audio-modulated Gains do.

Tests cover bit-equivalence with unfused, live `set_control` on
the elided Add node moving the bias, the gate stopping at
audio-rate Add, and Gain+Add chain composition.

### 4.D Block-rate regions

Existing IR-level rate propagation (`MetaSonic.Bridge.IR.propagateRates`) is
coherent: each node's output rate is the join of its kind floor with its
inputs' rates. Producer floors (`KSinOsc`, `KSawOsc`, `KNoiseGen`, `KLPF`,
`KEnv`, `KBusIn`, …) are `SampleRate`, so any reachable consumer of an
audio producer also lifts to `SampleRate`. That part of the lattice is
not broken; it answers a different question than block-latch
optimization needs.

The §4.D problem is that *node output rate* alone is too coarse to license
block-rate regions. A `KGain` whose only consumer is the absorbed sink is
sample-rate by output, but its `amount` slot may be a scalar `CompileRate`
constant; an `LPF`'s `freq` and `q` are block-latched by the C++ runtime
even when wired to a sample-rate source (the kernel reads only sample 0
of the input span and reconfigures `q::lowpass` once per block).

The decisive metadata for §4.D is *per-input consumption policy at the
destination port*, not the source's output rate. §4.D.1 (preserving
`rnRate` into `RuntimeNode` and surveying its distribution) confirmed
this empirically: 100 % `SampleRate` across the entire surveyed corpus.
Per-node output rate cannot be the lever.

§4.D.2 landed as the descriptive follow-up. It added per-kind /
per-port consumption-rate metadata (`PortConsumptionRate` /
`PortInfo` / `portInfo` in `MetaSonic.Types`; helpers in
`MetaSonic.Bridge.Compile.EdgeRates`), an edge-rate survey
joining each `rnInputs` edge against the destination's read
policy, and a /producer-grouped/ opportunity headline. The
producer grouping is load-bearing: a sample-rate producer that
feeds both a `PortBlockLatched` port and a `PortSampleAccurate`
port must remain sample-rate to serve the sample-accurate
consumer, so it is not an opportunity even though one of its
edges lands in a non-sample-accurate bucket.
`sampleRateOpportunityProducers` applies the per-producer rule
per graph; the survey concatenates the lists across rows. Phase
ports are classified `PortIgnored` (the runtime silently drops
`RFrom` edges to oscillator port 1) and excluded from the count.

Empirical signal on the surveyed corpus: 4 sample-rate producer
nodes across 4 distinct kinds (`KAdd`, `KEnv`, `KSmooth`,
`KSinOsc`) qualify as opportunities, out of 235 `RFrom` edges
total. That's small but non-zero, and the producer-kind
diversity argues against treating it as a corner case. The
decision: preserve the metadata, keep watching the number,
and park a runtime block-rate execution path until the signal
grows. New kernels are not the lever either — the ranked
missed-shape table still classifies Tri/Pulse/Add filtered tails
as low-signal.

Rate-distinguished regions remain a precondition for §4.E's
parallelism story to be as cheap as possible — a sample-rate
region driven entirely by control-latched inputs has lower
per-block work than one driven by audio inputs, and the scheduler
should know that when packing regions onto threads — but §4.E
does not strictly require §4.D and can ship with conservative
scheduling. The §4.D descriptive metadata stays in place to feed
whatever decisions §4.E eventually makes.

### 4.E Region-level parallelism — runtime substrate test-gated, default off

Independent regions (no shared bus hazards) can run on separate
threads. Another design difference from sc3/supernova: this is
cleaner than SuperNova's ParGroup model because hazard analysis
is structural, not manual — `BusFootprint` already records each
template's writes / live-reads / delayed-reads, and the same
shape can be lifted to per-region granularity.

Current status:

1. **Region scheduling metadata — done.** Per-region
   `BusFootprint` metadata, `regionDependencies`, and the
   live-bus barrier policy are in place. `KBusIn`, `KOut`, and
   `KBusOut` stay on the barrier path for normal scheduling;
   `KBusInDelayed` does not induce same-block ordering.
2. **Deterministic linear fallback — done.** `regionSchedule`
   validates dense region order, preserves barrier positions,
   topologically sorts free segments, and remains the stable
   fallback shape for loaders and runtime comparison.
3. **Layered descriptive plan — done.** `layeredRegionSchedule`
   exposes `ScheduleStep`s: pinned barriers plus stable free
   layers. Each `FreeLayer` carries explicit
   `SharedWriteHazard`s for same-layer writes to the same bus.
4. **Survey split — done.** `--fusion-survey` distinguishes
   full-layer width runnable without reduction (`runW` /
   `tplRunW`) from width that needs deterministic reduction or
   serialization (`redW` / `tplRedW`), with hazard counts
   (`haz` / `tplHaz`). This remains descriptive evidence, not a
   turn-on policy.
5. **Deterministic bus-reduction substrate — done, test-gated.**
   Sink writes route through `BusWriteTarget`; canonical writer
   slots are reserved at dispatch boundaries; contribution
   storage is sized from polyphony and sink-writer counts; and
   reduction mode can capture/fold writer-slot buffers in
   canonical order. Direct and reduction modes are bit-identical
   across hand-built C++ cases and the Haskell demo / survey
   corpus.
6. **Global schedule ABI and serial executor — done, opt-in.**
   Haskell loaders ship per-template schedule-step metadata to
   the runtime; the runtime builds a per-block global schedule and
   bands it into barriers / free bands. An opt-in serial executor
   consumes those bands while preserving the legacy executor as
   fallback for metadata-free construction paths.
7. **Worker-pool Free-band dispatch — done, test-gated.**
   The runtime owns a worker pool configured through the test ABI.
   Eligible Free bands dispatch through it under
   `rt_graph_test_set_global_schedule_execution` +
   `rt_graph_test_set_worker_pool_size`; direct-mode sink bands
   serialize explicitly, while reduction-mode sink bands can use
   deferred per-slot folding after the worker join. C1c tests run
   the full T-9 corpus under `pool_size=3` and preserve byte
   equivalence. The dispatch primitive now publishes work and joins
   with atomics only on the audio thread; thread start/stop remains a
   construction-time operation.
8. **Bench, corpus refresh, and turn-on decision — done, default-off.**
   The C++ synthetic bench and Haskell-loaded worker bench are in
   place. Synthetic sink-free Free-band compute only wins at enough
   width / block work; reduction-backed sink dispatch still loses on
   the measured grid. Targeted free-only probes are positive and keep
   C1d investigation alive, but no row supports default-on worker
   scheduling. Current numbers and the standing decision live in
   `notes/2026-05-09-phase-4e-worker-turn-on-decision.md`.
9. **C1d-a region work-item metadata — done, observational.**
   The runtime now expands each `GlobalScheduleEntry` into
   `RegionLayerWorkItem`s, one per scheduled region item, with
   precomputed writer-slot subranges and counters that distinguish
   sink-free C1d candidates from sink-bearing serialized groups.
   Capacity is reserved off the audio path using the same
   `max(polyphony, occupied)` discipline as the global schedule. The
   executor still ignores this table; C++ tests pin non-contiguous
   region ordinals, writer-slot subranges, lowered-polyphony capacity,
   and reset behavior. Review note:
   `notes/2026-05-09-c1d-a-region-work-item-metadata-review.md`.

Next §4.E slice:

1. **C1d-b serial region-item executor — next implementation slice.**
   Use the C1d-a work-item table for execution, but only serially and
   only behind the existing global-schedule test switch. The gate is
   strict byte-equivalence against the current global-schedule serial
   executor on hand-built C++ cases and the Haskell T-9 corpus. This
   slice must not introduce worker dispatch yet.
2. **C1d-b hardening test before parallel work.** Add a mixed-shape
   regression:
   `FreeLayer(region_without_sink, region_with_sink)` should report
   `candidate_entry_count = 0`, `candidate_item_count = 0`, and
   `serialized_sink_entry_count = 1`. This pins the `has_sink_writer`
   OR logic before C1d-c starts relying on the candidate counters.
3. **C1d-c sink-free parallel region items — only after C1d-b.**
   Dispatch sink-free multi-region `FreeLayer` items through the
   existing worker pool. Required gates: counter-confirmed region-item
   dispatch, bit-identical output, unconditional join before the next
   schedule band, release/free lifecycle unchanged, and full T-9 under
   schedule execution + reduction mode + `pool_size=3`.
4. **C1d-d bench and decision refresh.** Rerun `--fusion-survey`,
   `--worker-bench`, and the C++ synthetic worker bench after C1d-c.
   Keep timing claims subordinate to counters: only rows with
   region-item worker dispatch actually happening can support a
   turn-on decision. Update
   `notes/2026-05-09-phase-4e-worker-turn-on-decision.md` after the
   data is collected.
5. **More representative workload only if C1d is pursued further.** The
   current C1d candidates are survey rows, not default-on evidence.
   Before spending runtime complexity, add or identify real
   Haskell-loaded demos with enough region-layer DSP work to have a
   plausible crossover point. Useful target shapes remain:
     - polyphonic synth with shared master FX (N voice templates →
       BusOut → master template BusIn → master FX → Out);
     - parallel FX rack (split → N parallel processing chains → join);
     - multi-band processing (input → N band splits → per-band chains
       → join);
     - drum machine (N drum templates writing the same master BusOut).
6. **No public switch or default-on path yet.** Do not expose worker
   scheduling outside the test/bench ABI until a successor decision
   record replaces the current default-off decision with explicit
   corpus and threshold criteria.

**Stop condition.** After two corpus + bench iterations with no row
showing > 1.0x parallel speedup (counter-confirmed `parallel_bands
> 0`), freeze Phase C as test/bench gated and revisit only when a
specific use case demands runtime parallelism. This bounds the work;
the absence of such a bound is how parallelism projects accrete
indefinitely.

**The C0–C1 substrate has value independent of parallel dispatch.**
Even if Phase C parallelism never ships, the global schedule, banded
view, lifecycle hoist, and writer-slot pre-assignment are the
substrate for deterministic bus reduction (§4.E.2 fold ordering),
schedule introspection (`--fusion-survey` corpus FreeLayer-width table),
and future RCU-style topology swap (Phase 5). A "no parallelism"
outcome would not retire that infrastructure.

---

## 5 — Hot Graph Replacement

Replace a running MetaDef with a recompiled version **without audible glitches**.

### 5.1 RCU-based topology swap

The runtime already targets RCU-style reconfiguration. Formalize the protocol:
new `MetaDef` is compiled and lowered while the old one plays; swap happens at a
block boundary; old instance state is migrated where node identity is preserved.

### 5.2 State migration policy

Define which node states survive a hot swap (phase continuity for oscillators,
filter memory, envelope position) and which are reinitialized.

Edit a graph in the Haskell DSL, recompile, and hear the change without
restarting audio.

---

## Phase 6 — Extended DSP and Ecosystem

Lower priority, hold implementation until core is more stable.

- **Spectral processing:** Streaming DFT nodes for vocoder, spectral freeze,
  convolution.
- **Buffer I/O:** Sample playback, granular synthesis, recording into buffers.
- **OSC control interface:** Receive and send OSC for integration with other
  tools.
- **Sequencing / pattern layer:** Haskell-side pattern system (already
  prototyped) driving the server via timed control messages.
- **Plugin hosting:** Load external audio plugins (VST3/CLAP) as opaque nodes.

---

## Design Principles

1. **Haskell compiles, C++ executes.** All graph semantics, rate inference,
   effect analysis, and topological ordering happen before the FFI boundary. The
   C++ runtime is intentionally _as simple as possible_ at each stage.

2. **Q is DSP substrate, not architecture.** Q is just the starting
   point, it provides oscillators, filters, envelopes, delays, smoothing, audio
   I/O, and MIDI. It does not own graph topology, scheduling, or instance
   management.

3. **Compiled graphs are stronger than SynthDefs.** A MetaDef carries execution
   order, rate annotations, and (eventually) resource-hazard metadata.
   SuperCollider's SynthDef is a template; a MetaDef is a template _plus_ a
   proof of safe execution.

4. **No symbolic lookups on the audio thread.** Dense indices, pre-resolved
   order, pre-allocated state. This is already true and _must_ stay true at every
   stage.

5. **Compiler-derived ordering beats manual ordering.** SuperCollider requires
   users to manage node order and group structure to avoid bus-dependency bugs.
   MetaSonic can compute safe ordering from effect annotations, giving the same
   flexibility with much _less_ runtime superstition.

6. **Regions are the scheduling unit, not nodes.** Individual UGens are too
   fine-grained for efficient scheduling. Fusion, SIMD, and threading all target
   regions.
