---
title: "Inside q_lib: How Q Works, How We Use It, and How to Extend It"
date: 2026-03-30
tags: [metasonic, tinysynth, architecture, c++, q-dsp]
description: >
  Q DSP library internals — unit types, function-object composition,
  and the processor catalog — and how tinysynth integrates q_lib
  without coupling its graph runtime or FFI boundary to Q types.
---


There is a moment in the life of every audio project where you have to decide
what sits at the bottom of the stack. Not the language you compile from, not the
graph runtime, not the scheduler — but the actual *stuff* that touches samples.
The primitives. The filters, the oscillators, the envelopes, the delay lines.
The things that, in SuperCollider, are UGens; in Pure Data, externals; in Faust,
primitive signal processors.

For MetaSonic's C++ runtime — tinysynth — we chose to build on [Joel de Guzman's
Q DSP Library](https://github.com/cycfi/q). This post goes into detail on how
q_lib works internally, what makes it different from writing C++ DSP code in
other frameworks, how we use it in practice, and how to extend it with your own
processors. If you're coming from SuperCollider or PD, this should also clarify
what a "no-framework" approach to audio DSP looks like in modern
functional-style C++.

---

## The Architecture of q_lib

### Two layers, one optional

Q is split into two layers with a strict dependency boundary:

```
q_lib   →   header-only core DSP library (depends on: C++ stdlib only)
q_io    →   audio/MIDI I/O shim (depends on: q_lib, portaudio, portmidi)
```

This matters. The `q_lib` layer — the one containing all the DSP processors,
unit types, oscillators, filters, envelopes, and dynamics processors — has
**zero** external dependencies. This is not trivial. No PortAudio, no OS headers,
no threading primitives. It's a header-only library you can drop into any C++20
project by adding the include path.

The `q_io` layer wraps PortAudio and PortMidi behind thin adapters for
standalone use. The examples and tests use it, but it's explicitly designed to
be replaced. We will discard it soon. In our case, tinysynth should provide its
own PortAudio callback and MIDI handling, so we use `q_lib` alone. This is a
trivial task, because it has been already designed this way by Q's library
author, Joel de Guzman. 

Compare this with the dependency situation in SC or PD. To write a SuperCollider
UGen, you need the entire SC plugin API: `SC_PlugIn.hpp`, `InterfaceTable`,
`Unit`, `World`, `RTAlloc` — your code cannot exist without the server. A PD
external requires `m_pd.h` and the PD runtime. `q_lib` processors require
nothing beyond standard libraries such as `<cmath>`, its friends, plus what you
need for a more specialized algorithm.

### The file structure

The `q_lib` core is organized into the following functional directories:

```
q_lib/include/q/
├── detail/     internal helpers used by the rest of the library
├── fft/        FFT primitives
├── fx/         effects processors (delay, filters, dynamics, etc.)
├── pitch/      pitch detection facilities
├── support/    fundamental types, units, literals, concepts
├── synth/      oscillators, envelope generators, window functions
└── utility/    ring buffers, helper functions
```

Everything lives in the `cycfi::q` namespace. By convention:

```cpp
namespace q = cycfi::q;
using namespace q::literals;
```

That second line brings the user-defined literals (`_Hz`, `_ms`, `_dB`, etc.)
into scope — arguably the most distinctive feature of the library.

---

## The Unit Type System

### Why raw floats are dangerous

Every other programmer has been probably bitten by this: you pass a frequency
value where a duration is expected, or a linear gain where decibels should go,
or a sample count where seconds are needed. In SuperCollider UGen code,
everything is `float`. In PD externals, everything is `t_float` or `t_sample`.
The compiler cannot distinguish between 440 (Hz), 440 (samples), or 440
(milliseconds). Convention and documentation are your only guardrails.

Q addresses this through distinct wrapper types — frequency, duration, decibel,
phase, period — that are structurally separate at the type level. A frequency is
not a duration, and no implicit conversion exists between them. Extracting raw
numeric values requires an explicit conversion: `as_float` / `as_double` pull
the stored value out of `frequency`, `duration`, `pitch`, and `interval`, while
`lin_float` / `lin_double` perform the log-to-linear conversion specific to
`decibel`. User-defined literals (`440_Hz`, `350_ms`, `24_dB`) construct these
types from numeric constants with both readability and compile-time safety.
Separately, Q uses C++20 concepts (`Arithmetic`, `IndexableContainer`,
`RandomAccessIteratable`) to constrain its generic interfaces — ensuring that
containers, buffers, and iterators satisfy structural requirements checked at
compile time rather than failing silently at runtime.


### The unit types

Q provides six core unit types:

`frequency` — cycles per second. Constructed via `440_Hz`, `1.5_kHz`,
 `0.5_MHz`. Internally stores a `double`. Provides a `.period()` method
 returning the reciprocal as a `period` type. Explicit conversion back to raw
 float via `as_float(f)` or `as_double(f)`.

`duration` — a span of time. Constructed via `350_ms`, `1_s`, `10.5_us`.
 Also backed by `double`. Cannot be accidentally used where a `frequency` is
 expected.

`period` — the inverse of frequency, semantically distinct from `duration`.
 You get it from `frequency::period()`, or construct it directly. This
 separation matters: a period is the reciprocal of a specific frequency, while a
 duration is an arbitrary time span. In practice they might hold the same
 numeric value, but they mean different things.

`phase` — fixed-point 1.31 format representing 0 to 2π. This is specifically
 designed for oscillators. The 31 fractional bits give sub-sample accuracy for
 phase accumulation without the drift problems of floating-point phase.
 Arithmetic wraps naturally at 2π due to the fixed-point representation.

`decibel` — logarithmic ratio. Constructed via `24_dB`, `-3.5_dB`.
 Conversion to linear gain via `lin_float(d)`. The library uses decibels
 _natively_ in its dynamics processors — compressors and expanders accept and
 return `decibel` values, processing in the log domain rather than converting
 back and forth.

`interval` (and its derivative **`pitch`**) — musical intervals expressed in
 semitones and cents, with pitch names. **Note**: This newest Q's unit
 type (v1.5-dev) and it connects the frequency system to musical temperament.

### How this works at the type level

Each unit type inherits from a common `unit` base that provides relational
operators (`<`, `>`, `==`, etc.) and arithmetic operators (`+`, `-`, `*`, `/`)
where they make sense. But crucially, these operations are _constrained_: one
can add two `duration` values together, and you can multiply a `frequency` by an
integer (to get a harmonic), but you cannot add a `frequency` to a `duration`.
The C++ compiler rejects it.

```cpp
auto a = 440_Hz + 220_Hz; // OK: frequency + frequency → frequency
auto b = 440_Hz * 3;      // OK: third harmonic
auto c = 3_ms + 5_ms;     // OK: duration + duration → duration
auto d = 440_Hz + 3_ms;   // ERROR: cannot add frequency and duration
auto e = 24_dB;           // OK: decibel
float g = lin_float(e);   // Explicit Conversion: ≈ 15.85
```

For instance: the literal operators are `constexpr`, so the unit values can be
evaluated at compile time. 

### Contrast with SC/PD

In a SuperCollider UGen, you'd write:

```cpp
float freq = IN0(0);   // a float
float dur  = IN0(1);   // a float
```

If someone patches the wrong UGen output into the wrong input, the server
dutifully processes the values. The bug manifests as unpredictable sonic
artifacts, not a compiler error. You discover it by listening only.

Q's approach is more akin to what Faust's type inference gives you — but
expressed in C++ types rather than in a _separate_ type system, which restrain
modularity.

---

## Function Objects as the Building Block

### The core pattern

Every DSP processor in Q follows the same pattern: it is a `struct` with an
`operator()` that accepts input and returns output. Some processors also have
setup methods (`.cutoff()`, `.config()`, etc.), but the processing itself
happens through the call operator.

Here's the mental model. A processor is an object one:

1. **constructs** with configuration parameters (frequency, duration, sample rate)
2. **calls** with input samples, receiving output samples
3. **composes** with other processors via ordinary function application

There is no base class. No virtual dispatch. No registration. No RTTI — the
runtime type identification machinery behind dynamic_cast and typeid. Because
the compiler sees the full concrete type of every processor at every call site,
it can inline aggressively and optimize the entire composition as a single
function.

### Stateless processors

Some Q processors carry no mutable state. The bandwidth-limited oscillators are
the canonical example. A square wave oscillator is a pure function from phase
and phase-increment to sample value:

```cpp
struct square_synth {
    constexpr float operator()(phase p, phase dt) const {
        constexpr auto middle = phase::middle();
        auto r = p < middle ? 1.0f : -1.0f;
        r += poly_blep(p, dt);
        r -= poly_blep(p + middle, dt);
        return r;
    }
};
```

This oscillator doesn't own its phase. It receives `phase` and `phase_dt` (the
phase increment per sample, which encodes the frequency) as arguments. Phase
accumulation is managed externally by a `phase_iterator`. The oscillator itself
is `const`-callable and can be _evaluated at compile time_.

This decomposition matters. In SuperCollider, `SinOsc` carries its own phase
state internally — there's no way to separate "the function that maps phase to
sample" from "the thing that accumulates phase."

In Q, these are distinct objects with distinct types:

```cpp
q::phase_iterator phase;     // owns the phase state
q::square_osc osc;           // stateless, maps phase 
phase.set(440_Hz, 44100);    // configure phase increment
float sample = osc(phase++); // advance phase, compute sample
```

### Stateful processors

Processors that need memory — filters, delays, envelope followers — carry
their state as member data. A `lowpass` filter holds its biquad coefficients
and the last two input/output samples (the z⁻¹ and z⁻² state). A `delay`
holds a ring buffer. A `peak_envelope_follower` holds the current peak and
its decay state.

```cpp
q::lowpass               lpf{1_kHz, 44100};   // biquad coefficients + z⁻¹/z⁻² state
q::delay                 dly{350_ms, 44100};  // ring buffer
q::peak_envelope_follower env{30_ms, 44100};  // running peak + decay state
```

The interface is uniform: you call them with `operator()` just like the
stateless processors. The difference is visible in the type: stateless
processors are `const`-callable; stateful ones are not. This is the same
const-correctness principle the language already provides — `q_lib` just uses
it consistently. Configuration-only objects like `compressor` — which
construct with a threshold and ratio but expose a `const operator()` because
they accumulate no per-sample state — sit on the stateless side of this
boundary even though they look heavier at a glance.

### Composition

Because processors are ordinary function objects, composition is ordinary
function application:

```cpp
float process(float s) {
    dly.push(s);                        // advance the delay line
    auto delayed  = dly();              // read the delayed sample
    auto filtered = lpf(delayed);       // filter the delayed signal
    return s + filtered * wet;          // dry + filtered wet
}
```

**Note**: At this layer, there is no graph, no wiring, no topological sort. The
C++ call tree _is_ the signal flow. The compiler inlines the entire chain into a
function.

`q_lib` uses this pattern internally at higher levels of abstraction. The
`signal_conditioner` — used in the pitch detection pipeline — composes a
highpass filter, a clipper, a dynamic smoother, an envelope follower, a noise
gate, and a compressor into a single `operator()`. The composition is explicit
in the code:

```cpp
inline float signal_conditioner::operator()(float s)
{
    s = _hp(s);                   // highpass
    s = _clip(s);                 // pre-clip
    s = _sm(s);                   // dynamic smoother
    auto env = _env(std::abs(s)); // envelope follower
    auto gate = _gate(env);       // onset gate
    s *= _gate_env(gate);         // apply gate envelope
    auto env_db = lin_to_db(env); // convert to dB
    auto gain = lin_float(_comp(env_db)) * _makeup_gain; // compress
    s = s * gain;
    return s;
}
```

Each of those member variables (`_hp`, `_clip`, `_sm`, `_env`, `_gate`,
`_gate_env`, `_comp`) is a function. The composite is built from fine-grained
parts that can be tested, replaced, and reused independently.

In SuperCollider terms, this is like writing a `SynthDef` — but the "graph" is a
function rather than a runtime data structure, and the "UGens" (again, at _this_
layer) are inlined function calls rather than dynamically dispatched objects in
a sorted execution list.

### Comparison with SC UGen processing

To appreciate what `q_lib` removes, here's the equivalent processing pattern in
a SuperCollider UGen:

```cpp
void MyProcessor::next(int nSamples) {
    float* in  = IN(0);
    float* out = OUT(0);
    for (int i = 0; i < nSamples; ++i) {
        // Insert DSP code here
        out[i] = result;
    }
}
```

Inside a SC UGen, you process a _block_ of samples in a callback. You read from
input buffers via macros. You write to output buffers via macros. The server
calls you. Your code is structurally coupled to the sc block-processing model.

`q_lib` has no such contract. Your DSP logic is just DSP logic.

---

## The Processor Catalog

`q_lib` provides processors organized into functional categories. Here's what's
available and how each category works.

### Biquad Filters

The [Robert Bristow-Johnson biquad](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt):
family `lowpass`, `highpass`, `bandpass_csg` (constant skirt gain), `bandpass_cpg`
(constant peak gain), `allpass`, `notch`, `peaking`, `lowshelf`, `highshelf`.
Each is constructed with a frequency (or frequency and Q/gain) and a sample
rate:

```cpp
q::lowpass  lp{1_kHz, 44100};
q::highpass hp{80_Hz, 44100};
q::peaking  pk{6.0, 2_kHz, 44100, 1.5}; // gain (raw dB), freq, srate, Q
```

They share a common biquad implementation internally but present distinct
constructor signatures that enforce correct parameterization. You can't
accidentally construct a peaking filter with only a frequency and sample rate.

All filters support runtime reconfiguration via `.config()` or `.cutoff()`
methods — of course, very important for filters.

### Envelope Followers and Generators

Two separate categories, often confused in other systems:

**Envelope followers** (analysis): `peak_envelope_follower`,
 `ar_envelope_follower`, `fast_envelope_follower`, `fast_ave_envelope_follower`,
 `fast_rms_envelope_follower`. These take audio input and extract an amplitude
 envelope. They return `float` values representing instantaneous envelope level.

**Envelope generators** (synthesis): the `envelope_gen` class, which implements
 a multi-segment envelope (ADSR plus). This is a generator — it takes no
 audio input and produces an envelope contour when triggered. It's driven by
 time, not by signal.

This separation is explicit in the directory structure (`fx`/`synth`) and in the
type signatures. In SuperCollider, `EnvGen` (the generator) and `Amplitude` (the
follower) are both UGens with the same interface — you tell them apart
documentation and convention. `q_lib` makes this structural distinction by
design.

### Dynamics Processors

`compressor`, `soft_knee_compressor`, `expander`, `agc` (automatic gain
control). These are unusual in how they handle signal representation: they
accept and return `decibel` values, not raw samples. The dynamics processor
operates entirely in the logarithmic domain:

```cpp
q::compressor comp{-18_dB, 1.0/4.0};  // threshold, ratio

auto env = env_follower(std::abs(s)); // get linear envelope
auto env_db = lin_to_db(env);         // convert to dB
auto gain_db = comp(env_db);          // compress in dB domain
s *= lin_float(gain_db);              // apply gain
```

This is a deliberate design choice. Most textbook compressor implementations
shuttle between linear and dB domains internally; `q_lib` keeps everything in dB
and lets you convert at the boundaries. The result is cleaner code and better
numerical behavior in the extreme ranges.

### Oscillators (Synthesizers)

Bandwidth-limited oscillators via PolyBLEP: `saw_osc`, `square_osc`,
`pulse_osc`, `triangle_osc`. Plus generators for window functions
(`blackman_gen`, `hann_gen`, `hamming_gen`) and ramps (`linear_gen`,
`exponential_gen`).

All oscillators work on the `phase` / `phase_iterator` model described above.
Oscillators are _pure functions_ from phase to sample; the phase iterator
manages accumulation and frequency:

```cpp
q::phase_iterator phase;
q::saw_osc saw;

phase.set(220_Hz, 44100);

for (auto i = 0; i < nframes; ++i) {
    output[i] = saw(phase++);
}
```

---

**Important implementation detail**: The `phase` type uses a fixed-point 1.31
 format: a 32-bit unsigned integer where 1 bit is the integer part and 31 bits
 are fractional. The full range of the integer (0 to 2³²−1) maps to one complete
 cycle (0 to 2π). This gives roughly 4.3 billion discrete phase positions per
 cycle — uniform across the entire range.

Compare this with the alternative approaches:

A naive `float` phase accumulator (common in hand-rolled C++ oscillators) has
only 23 mantissa bits. Near zero the precision is fine, but near the wrap point
(approaching 1.0 or 2π) it degrades to roughly 8.4 million effective positions
per cycle — about 512× coarser than `q_lib`'s fixed-point distinction. This
non-uniform precision is the source of pitch-dependent tuning drift in
float-based oscillators: higher frequencies accumulate phase faster, spending
more time near the wrap point where `float` is least precise.

SuperCollider's oscillators use an internal `int32` phase accumulator with table
lookup — similar in precision to `q_lib`'s approach, but the phase type is
buried inside each UGen and not reusable or composable. PD's uses a `double`
accumulator (52-bit mantissa, ~4.5 × 10¹⁵ effective positions), which is more
precise than both, but at twice the memory bandwidth.

`q_lib`'s `uint32` hits the practical sweet spot: uniform precision across the
cycle, free modulo-2π via unsigned overflow (no `fmod` or conditional branch
needed), and half the width of `double` — which matters when you're running a
large number of oscillators per audio block.

---

### Miscellaneous Effects

These are the units that don't fit neatly into the filter/envelope/dynamics
categories but show up in a processing chain:

**`delay`** — a fractional delay line backed by a ring buffer with interpolated
 reads. Constructed with a duration and sample rate (`q::delay{350_ms, 44100}`).
 Supports both write-then-read (`push` / `operator()`) and indexed access for
 multi-tap configurations. The fractional part is important: many effects
 (chorus, flanger, physical models) need delay times that don't fall on exact
 sample boundaries. `q_lib` handles the sub-sample interpolation internally. In SC,
 this corresponds to `DelayL` / `DelayC`; in PD, `delread~` / `delread4~`.

**`moving_sum` / `moving_average`** — windowed accumulators that update in O(1)
 per sample by adding the new sample and subtracting the one falling off the
 window. Useful for smoothing control signals, computing running statistics, or
 building higher-level analysis tools. SC's `RunningSum` provides equivalent 
 functionality as a UGen (plus its scaffolding: block processing, input/output 
 buffer pointers, rate handling, etc.; `q_lib`'s version is a function that 
 composes freely independent of any framework).

**`noise_gate` / `onset_gate`** — the noise gate attenuates signal below a
 threshold; the onset gate detects transient onsets and opens a window around
 them. Both work on envelope levels rather than raw samples, consistent with `q_lib`'s
 convention of separating envelope extraction from dynamics processing. The
 onset gate is particularly relevant for the pitch detection pipeline, where you
 need to know when a note begins before you can track its pitch.

**`one_pole_lowpass`** — a single-pole IIR filter, the simplest possible lowpass
 (6 dB/octave roll-off). Frequently used for parameter smoothing — when a filter
 cutoff changes, you don't want the raw parameter jump to cause a click. Running
 it through a one-pole smoother gives an exponential glide. In SC, `Lag.kr` does
 the same thing, as a UGen.

**`dc_block`** — removes DC offset from a signal. A high-pass filter with a very
 low cutoff (typically a few Hz). Essential after any nonlinear processing
 (waveshaping, rectification) that might introduce a DC component. SC: `LeakDC`.

**`dynamic_smoother`** — an adaptive smoother that adjusts its smoothing amount
 based on the signal's rate of change. Faster changes get less smoothing,
 preserving transients while still filtering noise. This is more sophisticated
 than a fixed one-pole and shows up in pitch detection pipeline.

**`schmitt_trigger`** — a comparator with hysteresis: the signal must cross a
 high threshold to turn "on" and a low threshold to turn "off." Prevents rapid
 toggling when a signal hovers near a single threshold. Used internally in the
 zero-crossing analysis and pitch detection, but useful in any context where you
 need clean boolean events from a noisy continuous signal.

**`peak`** — tracks the peak value of a signal over time, with configurable
 decay. Useful for metering and for feeding dynamics processors.

### Utilities

**`ring_buffer`** — a fixed-size circular buffer with O(1) push and indexed read
 access. This is the underlying storage for `delay` and other windowed
 processors. The implementation uses a power-of-two size with bitwise masking
 for the wrap — avoiding the modulo operation, similar to how `phase` avoids
 `fmod`.

**`fractional_ring_buffer`** — extends `ring_buffer` with interpolated reads at
 non-integer indices. When you read at index 3.7, it interpolates between
 samples 3 and 4. This is what makes fractional delay lines work — and by
 extension, any effect that needs continuously variable delay (chorus, pitch
 shifting, Karplus–Strong synthesis).

Both containers are constrained by C++20 concepts: `IndexableContainer`
(requires `operator[]` and `size()`) and `RandomAccessIteratable` (requires
`begin()` / `end()` returning random-access iterators). These concepts aren't
just documentation — they're compile-time constraints. If you write a generic
function that operates on Q buffers, constraining the template with
`q::concepts::IndexableContainer` means the compiler rejects any type that
doesn't satisfy the structural requirements, with clear error messages rather
than deep template instantiation failures.

### Pitch Detection

This is one of `q_lib`'s signature contribution and one of the reasons the
library exists. Joel de Guzman's pitch detection work has gone through two
generations:

**v1.0 — Bitstream Autocorrelation (BACF):** The signal is converted to a 1-bit
 representation (above zero = 1, below zero = 0), then autocorrelated using
 bitwise XOR and population count operations. This is orders of magnitude faster
 than traditional float-domain autocorrelation because each
 "multiply-and-accumulate" becomes a single XOR followed by a hardware
 `popcount` instruction. The trade-off is that you lose amplitude information —
 but for pitch detection, you only need the periodicity, not the magnitude.

**v1.5 — Hz pitch detection system:** The successor algorithm integrates pitch
 detection and onset detection into a single pipeline. The onset detector
 identifies *when* a new note begins; the pitch tracker determines *what*
 frequency it is. Combining these avoids the common problem where a pitch
 tracker reports spurious frequencies during transients (the attack portion of a
 note, where the waveform hasn't stabilized yet).

The pitch detector is itself a compelling example of compositional architecture.
It's built from the same function objects available everywhere:
`signal_conditioner` (which itself composes a highpass, clipper, dynamic
smoother, envelope follower, noise gate, and compressor), zero-crossing
analysis, and autocorrelation. The complex behavior emerges from composing
simple, testable parts — the same pattern the rest of the library follows.

For `tinysynth`, pitch detection isn't a primary use case on every layer
(`tinysynth` generates audio from known frequencies rather than analyzing
unknown ones), but the `signal_conditioner` chain is a useful reference for how
to structure complex processing pipelines from primitives.



---

## How We Use q_lib in tinysynth

### The integration boundary

`tinysynth`'s job is to provide what `q_lib` deliberately does not: a graph
runtime, buffer management, multi-rate scheduling, and a node model. `q_lib`
provides the leaf-node processors (in a safer, simpler and more modular style);
tinysynth provides the tree they live in.

In our architecture, a `tinysynth` node (planned, not in the code yet,
represented as a `std::variant` over a descriptor table of node kinds) wraps one
or more functions. When the graph evaluator visits a node, it calls the
processor's `operator()` with samples from the node's input bus and writes the
result to the output bus.

A simple sketch:

```cpp
struct lowpPass {
    q::lowpass filter;
    void process(std::span<float> in, std::span<float> out, int nframes) {
        for (int i = 0; i < nframes; ++i) {
            out[i] = filter(in[i]);
        }
    }
};
```

The relevant insight is that `q::lowpass` doesn't know about tinysynth's bus
system, block size, threading model, or memory allocation strategy. It just
filters samples when called. `tinysynth` owns the loop, the buffers, and the
scheduling; `q_lib` owns the dsp math at the sample level.

### Code generation from Haskell

This separation pays off in our compiler pipeline. When the MetaSonic bridge
compiles a Haskell audio graph into C++ source, it emits constructor calls for
processors and inline processing code. The generated code uses explicit
constructors rather than the user-defined literals:

```cpp
// MetaSonic bridge:
//   lowpass (freq 1000) (input 0)
q::lowpass _node_3{q::frequency{1000.0}, srate};

// processing function:
out[3] = _node_3(in[0]);
```

The explicit constructor form (`q::frequency{1000.0}`) is preferred over the
literal form (`1_kHz`) for generated code. The bridge's IR already carries typed
numeric values from Haskell — emitting `q::frequency{val}` maps directly from
the IR without string-formatting literal suffixes. The literals are syntactic
sugar for human readers; the constructors are a better fit for codegen.

The code generator doesn't need to emit SC-style or PD-style boilerplates, or
plugin-framework scaffolding. It emits function construction. The C++20 compiler
handles from there.

### Where q_lib's types live — and where they don't

An important architectural decision: `q_lib`'s unit types (`frequency`,
`duration`, `decibel`) appear _inside_ node implementations, but not in
tinysynth's public API. The descriptor table, parameter system, and FFI boundary
all work with raw numeric values and _our_ own semantic tags.

This is deliberate. Consider the FFI boundary between Haskell and C++. The
Haskell side has its own type safety — e.g. `Freq` and `Duration` types in the
Haskell IR. The C++ side has `q_lib`'s types. But the wire between them is raw
`double`:

```cpp
void set_filter_freq(NodeId id, double freq_hz) {
    auto& node = graph.get<LowpassNode>(id);
    node.filter.cutoff(q::frequency{freq_hz}, srate);
}
```


The type safety is restored at the C++ boundary. The raw `double` only exists
during the FFI crossing. The same principle applies to the descriptor table. A
node parameter declaration says "this parameter is a `float` tagged as
`ParamKind::Freq`" — not "this parameter is a `q::frequency`." If we ever wanted
to swap Q's lowpass for a hand-rolled filter or a different library's
implementation, the descriptor table remains agnostic. Q is a leaf-node
dependency, not a load-bearing architectural one.

In practice, this means three layers of type safety in the MetaSonic stack, each
with its own vocabulary:

```
Haskell IR:      Freq 1000.0          (our types, Haskell type inference)
FFI wire:        1000.0               (untyped, minimal surface)
C++ node impl:   q::frequency{1000.0} (q_lib types, C++ checking)
```

Each boundary reconstructs safety from the layer above. No single type system
spans the full stack, and that's the tradeoff: it keeps the layers replaceable.

**Design Note for MetaSonic**: FFI functions that pass parameter values 
(frequency,duration, gain, threshold, envelope time, ratio) should use `Double` on the
Haskell side and `CDouble` at the boundary — this matches `q_lib`'s internal double
precision for coefficient computation and avoids a narrowing-then-widening round
trip through float. Sample buffer pointers remain `Ptr CFloat`. If the Haskell IR
currently represents parameter fields as `Float`, those fields should be promoted
to `Double` before the convention hardens across the codebase.


### Two numeric domains: parameters vs. samples

Working with `q_lib` surfaces an important precision distinction that the FFI
contract needs to respect. `q_lib` uses two different precisions for two
different purposes:

**Parameters** — frequency, duration, gain, threshold, ratio, envelope times —
 are backed by `double` inside `q_lib` unit types. When you construct
 `q::frequency{440.0}` or `q::duration{0.35}`, the internal representation is
 `double`. The biquad coefficient calculations, the phase increment computation,
 the dB-to-linear conversion — all of these happen in `double` precision because
 parameter accuracy matters. A filter cutoff specified imprecisely produces the
 wrong filter. A tuning value like 441.37289 Hz should survive the trip from
 Haskell to C++ without floating-point rounding artifacts.

**Samples** — the per-frame audio data flowing through `operator()` — are
 `float`. This is universal in audio: PortAudio callbacks deliver `float*`,
 SuperCollider UGens process `float*`, DACs accept 24-bit or less. Single
 precision gives 144 dB of dynamic range, far beyond what any audio signal
 needs. Doubling the precision would double the memory bandwidth for no audible
 benefit.

`q_lib` reflects this split internally. Its processors accept and return `float`
samples, but compute their coefficients from `double` parameters. The narrowing
from `double` coefficients to `float` state happens once at construction or
reconfiguration — not per sample.

The FFI contract should mirror this:

```
Haskell Double → CDouble → C++ double → q::frequency{val}
Haskell CFloat → float*  → C++ float  → processor(s)
```

This means parameter-setting FFI functions take `double`:

```cpp
void set_filter_freq(NodeId id, double freq_hz) {
    auto& node = graph.get<LowpassNode>(id);
    node.filter.cutoff(q::frequency{freq_hz}, srate);
}
```

While audio buffer pointers remain `float*`:

```cpp
void process_block(float* in, float* out, int nframes) {
    for (int i = 0; i < nframes; ++i)
        out[i] = graph.tick(in[i]);
}
```

The thing to watch for: if the Haskell IR represents parameter values as `Float`
(single-precision) and passes them through `CFloat` → `float` →
`q::frequency{(double)val}`, there's a narrowing-then-widening round trip. A
frequency of 440.0 survives this fine, but a precise tuning value loses bits
unnecessarily. Using `Double` in the Haskell IR for parameter fields — while
keeping sample data as `Float` — avoids the round trip entirely and aligns with
`q_lib`'s own internal precision split.

### When to use the literals

So where do `q_lib`'s user-defined literals (`_Hz`, `_ms`, `_dB`) actually
belong? In hand-written C++ code — and nowhere else.

If you're writing a new node kind directly in C++, or composing Q processors
into a custom effect, bring the literals into scope and use them freely:

```cpp
using namespace q::literals;

// Much simpler plug-in code writing in many ways, it is closer to writing a
// SynthDef in SC or Faust code, since there is minimal boilerplate.
struct ReverbTail {
    q::delay            dly{80_ms, 44100};
    q::lowpass          lpf{3_kHz, 44100};
    q::one_pole_lowpass smoother{20_ms, 44100};
};
```

This is dramatically more readable than `q::delay{q::duration{0.08}, 44100}`,
and the type safety catches real bugs — accidentally writing `q::delay{3_kHz,
44100}` is a compile error, not a subtle sonic artifact. The literals are one of
`q_lib`'s best features for human-authored code.

_But_ they don't propagate upward. The MetaSonic bridge doesn't emit them. The
FFI doesn't use them. The descriptor table doesn't reference `q_lib` types. The
boundary between "implementation detail" and "architectural interface" is clean:
`q_lib` types stay inside the node, raw values with semantic tags face outward.

---

## Extending q_lib — Writing Your Own Processors

### The contract

`q_lib` doesn't enforce inheritance or interfaces (no base class, no `virtual`).
But it does follow conventions that you should respect if you want your
processors to compose naturally with the rest of the library:

1. **Your processor is a `struct` with `operator()`.**

2. **Construction takes configuration parameters**, not sample data. Sample rate
is passed as `float sps` (not a `q_lib` unit type — this is a deliberate
pragmatic choice since sample rate isn't a "unit" in the same sense as frequency
or duration).

3. **`operator()` takes input values and returns output values.** The
input/output types depend on the processor: filters take and return `float`,
compressors take and return `decibel`, oscillators take `phase` and return
`float`.

4. **Stateless processors should be `const`-callable.** If your `operator()`
doesn't mutate state, mark it `const` (or `constexpr` if possible).

5. **Use q_lib's unit types** for parameters: `frequency` for cutoff/center
frequencies, `duration` for time parameters, `decibel` for thresholds and gains.

### Example: a simple waveshaper

Here's how you'd write a custom hyperbolic tangent waveshaper as a `q_lib`-style
processor:

```cpp
#include <q/support/literals.hpp>
#include <cmath>

namespace q = cycfi::q;

struct tanh_shaper {
    float drive;

    constexpr tanh_shaper(float drive = 1.0f)
        : drive{drive} {}

    float operator()(float s) const {
        return std::tanh(s * drive);
    }
};
```

This is stateless (the `drive` parameter is configuration, not stateful) and
`const`-callable. It composes with any other processor:

```cpp
q::lowpass lpf{2_kHz, 44100};
tanh_shaper shaper{3.0f};

float out = lpf(shaper(in)); // shape, then filter
```

### Example: a resonant feedback delay

A more interesting example that combines stateful processors with custom logic:


```cpp
struct feedback_delay {
    q::delay       dly;
    q::lowpass     lpf;
    float          feedback;

    feedback_delay(q::duration time, q::frequency cutoff, float fb, float sps)
        : dly{time, sps}
        , lpf{cutoff, sps}
        , feedback{fb}
    {}

    float operator()(float s) {
        auto delayed  = dly();
        auto filtered = lpf(delayed);
        auto out = s + filtered;
        dly.push(out * feedback);
        return out;
    }
};
```

Notice how this follows `q_lib`'s own patterns: construction with typed
parameters, processing via `operator()`, composition of internal Q objects. The
`feedback_delay` itself becomes a composable function object that could be used
inside yet another composite.

### Example: a custom oscillator

If you want to add a new oscillator waveform, follow the stateless-oscillator
pattern — take `phase` and `phase_dt`, return a sample:

```cpp
struct supersaw {
    static constexpr int NUM_SAWS = 7;
    static constexpr float DETUNE = 0.01f;

    float operator()(q::phase p, q::phase dt) const {
        float sum = 0.0f;
        for (int i = 0; i < NUM_SAWS; ++i) {
            float detune = 1.0f + DETUNE * (i - NUM_SAWS / 2);
            q::phase detuned_p = p * detune;
            q::phase detuned_dt = dt * detune;
            sum += q::saw_osc{}(detuned_p, detuned_dt);
        }
        return sum / NUM_SAWS;
    }
};
```

This reuses `q_lib`'s bandwidth-limited `saw_osc` as a building block and
composes multiple detuned copies. Because `saw_osc` is stateless and
`constexpr`-constructible, we can create it inline inside `operator()`.

### Example: dynamics processor in the decibel domain

If you're writing a dynamics processor, work in the `decibel` domain to match
`q_lib`'s convention:

```cpp
struct soft_gate {
    q::decibel threshold;
    q::decibel range;

    soft_gate(q::decibel thresh, q::decibel rng)
        : threshold{thresh}
        , range{rng}
    {}

    q::decibel operator()(q::decibel env) const {
        if (env >= threshold) return 0_dB;
        auto atten = env - threshold;
        return std::max(atten, -range);
    }
};
```

This integrates cleanly with Q's envelope followers and compressors in a
processing chain.

### Using C++20 concepts

Q v1.5 defines its own concepts (`Arithmetic`, `IndexableContainer`,
`RandomAccessIteratable`). If you're writing generic utilities that operate on
containers or buffers, constrain your templates with these:

```cpp
#include <q/support/basic_concepts.hpp>

template <q::concepts::IndexableContainer Buffer>
float rms(Buffer const& buf) {
    float sum = 0.0f;
    for (auto i = 0u; i < buf.size(); ++i)
        sum += buf[i] * buf[i];
    return std::sqrt(sum / buf.size());
}
```

This works with `multi_buffer`, `ring_buffer`, or any container satisfying the
concept.

---

## Q and the Larger Landscape

### Q vs. Faust

Faust's block diagram algebra is the closest architectural analog to `q_lib`'s
composition model: both treat signal processors as composable functions. The
difference is that Faust is a separate language with its own compiler; `q_lib`
is C++20 that reads like a DSL thanks to user-defined literals and function
objects. `q_lib` gives you Faust-like composition without a separate compilation
step — but, on the other side, without Faust's automatic parallelization and
formal semantics. That's why MetaSonic should do this task. 

### `q_lib` vs. writing raw C++ DSP

You can of course write a biquad filter from scratch in C++. We have been doing
that. What `q_lib` provides is not algorithms you couldn't write yourself — it's
a _coherent design language_: consistent use of function objects, type-safe
units, compositional structure, and a vocabulary of well-tested primitives. It's
the difference between having a collection of C functions and having a library
with a design and vocabulary.

For MetaSonic, that principle — small composable parts, type safety, no runtime
coupling — aligns perfectly with what we need. Our Haskell compiler provides
high-level musical abstractions. The bridge translates them into graph
topologies. And `q_lib` provides the DSP primitives at the leaves of those
graphs, processing samples with no unnecessary coupling to any runtime we might
outgrow.

---

## References

### Documentation & Source

- [Q DSP Library — GitHub Repository](https://github.com/cycfi/q)

### Articles by Joel de Guzman (Cycfi Research)

- ["My Sonic Quest: Adventures in DSP"](https://www.cycfi.com/2023/05/my-sonic-quest-adventures-in-dsp/) (May 2023) — Origin and design philosophy of the Q library.
- ["Q Audio DSP Library"](https://www.cycfi.com/2019/02/q-audio-dsp-library/) (February 2019) — Initial v0.9 beta announcement.
- ["Q Onwards to 1.0"](https://www.cycfi.com/2020/05/q-onwards-to-1-0/) (May 2020) — Synth examples, documentation progress, and design notes.
- ["Q Audio DSP Library 1.0 Beta"](https://www.cycfi.com/2023/06/q-audio-dsp-library-1-0-beta/) (June 2023) — 1.0 beta release and documentation approach.

### Pitch Detection Series (Cycfi Research)

- ["Fast and Efficient Pitch Detection: Bitstream Autocorrelation"](https://www.cycfi.com/2018/03/fast-and-efficient-pitch-detection-bitstream-autocorrelation/) (March 2018)
- ["Fast and Efficient Pitch Detection: Bliss!"](https://www.cycfi.com/2018/04/fast-and-efficient-pitch-detection-bliss/) (April 2018)
- ["Fast and Efficient Pitch Detection: Revisited"](https://www.cycfi.com/2020/07/fast-and-efficient-pitch-detection-revisited/) (July 2020)
- ["Fast and Efficient Pitch Detection: Power of Two"](https://www.cycfi.com/2021/02/fast-and-efficient-pitch-detection-power-of-two/) (February 2021)
- ["Pitch Perfect: Enhanced Pitch Detection Techniques (Part 1)"](https://www.cycfi.com/2024/09/pitch-perfect-enhanced-pitch-detection-techniques-part-1/) (September 2024) — The new Hz pitch detection system replacing BACF.

### Community

- [Cycfi Research Discord](https://github.com/cycfi/q) 
---

*MetaSonic is a Haskell-to-C++20 compiler pipeline for real-time audio
 synthesis. The Q DSP Library documentation is at
 [cycfi.github.io/q](https://cycfi.github.io/q/q/v1.5-dev/index.html). Follow
 MetaSonic development at
 [smoge.github.io/metasonic-bridge](https://smoge.github.io/metasonic-bridge).*