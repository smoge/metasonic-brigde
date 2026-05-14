# C++ Templates In Tinysynth

Date: 2026-05-14

Status: explanatory note for why `tinysynth/rt_graph.cpp` uses a small
amount of C++ template code, how those templates work, and where the
boundary should stay.

## Why This Matters Here

Tinysynth is a realtime audio runtime. Its hot path is not a good place
for avoidable dynamic dispatch, heap allocation, or generic frameworks
that make DSP behavior hard to audit. At the same time, some DSP node
families really do share the same control flow:

- LPF / HPF / BPF / Notch share the same biquad state and processing
  protocol;
- SinOsc / SawOsc / TriOsc share the same phase accumulation and
  frequency-input protocol;
- small numeric helpers such as finite-value sanitation work for both
  `float` and `double`.

C++ templates are useful in exactly these cases: the runtime behavior is
the same, the differing part is known at compile time, and we want the
compiler to generate direct specialized code without adding a runtime
abstraction layer.

The current tinysynth usage is intentionally narrow. Templates are used
for DSP families with a uniform shape, not as a replacement for the
explicit runtime `NodeKind` switch, C ABI entrypoints, or shape-specific
fused kernels.

## Template Basics

A C++ template is a compile-time pattern for generating code. The
template definition names one or more parameters, and each use of the
template with concrete arguments creates an instantiation.

For a function template:

```cpp
template <typename T>
static inline T sanitize_finite(T v, T fallback) noexcept {
  return std::isfinite(v) ? v : fallback;
}
```

the compiler can instantiate one version for `float`, another for
`double`, and so on. The source code has one body, but the compiled code
is type-specific at each call site.

For a class template:

```cpp
template <class Filter>
struct BiquadFilterState {
  Filter filter{q::frequency{1000.0}, kDefaultSampleRate, 0.707};
  double last_freq = -1.0;
  double last_q = -1.0;
};
```

the concrete aliases in `rt_graph.cpp` create separate state types:

```cpp
using LPFState = BiquadFilterState<q::lowpass>;
using HPFState = BiquadFilterState<q::highpass>;
using BPFState = BiquadFilterState<q::bandpass_cpg>;
using NotchState = BiquadFilterState<q::notch>;
```

This is not inheritance. `LPFState` and `HPFState` are different concrete
types generated from the same source pattern. There is no vtable and no
virtual call in the DSP loop.

`typename` and `class` mean the same thing in a template parameter list:

```cpp
template <typename T>
template <class T>
```

Both declare a type parameter. The codebase uses both forms in ordinary
C++ style.

## Instantiation

Templates are not executed as templates at runtime. They are expanded by
the compiler when concrete arguments are known.

This call:

```cpp
process_biquad_filter<LPFState>(g, inst, node_idx, nframes);
```

asks the compiler for a version of `process_biquad_filter` where `State`
is `LPFState`. This call:

```cpp
process_biquad_filter<HPFState>(g, inst, node_idx, nframes);
```

asks for a separate version where `State` is `HPFState`.

Inside each instantiation, references such as:

```cpp
auto *st = BiquadFilterStateAccess<State>::get(node.state);
```

are resolved at compile time to the matching specialization:

```cpp
template <>
struct BiquadFilterStateAccess<LPFState> {
  static LPFState *get(NodeState &state) noexcept {
    auto *st = std::get_if<LPFState>(&state);
    assert(st && "LPF node has non-LPF state");
    return st;
  }
};
```

That is how the shared processor keeps one implementation while still
preserving the old kind-specific assertion messages.

## Compile-Time Contracts

A template has an implicit contract: the concrete type passed into it
must provide the operations used by the template body.

For `BiquadFilterState<Filter>`, the `Filter` type must be usable like a
q biquad filter:

- constructible from `(q::frequency, sample_rate, q)`;
- configurable with `.config(q::frequency, sample_rate, q)`;
- callable as `filter(float)`.

There is no explicit interface declaration in this file. The compiler
checks the contract by compiling the instantiated body. If someone tries
to instantiate the template with a type that lacks `.config(...)`, the
build fails at compile time.

That is useful for tinysynth because it catches family-shape mistakes
early while keeping runtime processing direct.

## Function Objects And Lambdas

The oscillator helper uses two callable template parameters:

```cpp
template <class WaveFn, class Body>
static inline void drive_oscillator(
    RTGraph const &g,
    OscState &osc,
    std::span<const float> freq_in,
    double freq_control_default,
    int nframes,
    WaveFn wave_fn,
    Body body
) noexcept;
```

`WaveFn` is the waveshape callable. In the fused region kernels this is
passed directly as q_lib's `q::sin` or `q::saw` function object. In the
plain node processors it is passed as the spec's static `sample`
function, such as `SinOscSpec::sample`, which then calls the matching
q_lib waveshape. `Body` is what to do with each generated sample: plain
node processors use a lambda that writes to the node's output span,
while fused region kernels use bodies that feed the next operation or
sink accumulator.

Because `WaveFn` and `Body` are template parameters, the compiler sees
their exact types at each call site. A small lambda body can usually be
inlined into the generated loop. The helper therefore captures the
shared loop shape without forcing a virtual callback or `std::function`
allocation into the realtime path.

## Why Templates Fit The Biquad Family

The LPF / HPF / BPF / Notch kernels differ in which q_lib biquad
alternative they use. They do not differ in runtime protocol:

- read signal input from port 0;
- read cutoff input or control default;
- read Q input or control default;
- sanitize frequency and Q before coefficient math;
- reconfigure only when block-latched parameters change;
- preserve filter delay history across reconfiguration;
- process each sample through the persistent filter object.

That makes the family a good template target. The abstraction removes
repeated code while keeping behavior identical across all four filters.

The important detail is that the template boundary preserves the
contract. The state template records that all four filters are q biquad
siblings. The processing note records the block-latched behavior and
state-preserving reconfiguration. The access specializations preserve
specific assertion messages.

This is the right kind of template use: it removes mechanical
duplication without hiding a runtime distinction.

## Why Templates Fit The Plain Phase Oscillators

The plain phase oscillators also share one protocol:

- store persistent phase in `OscState`;
- resolve optional audio-rate frequency from port 0;
- use `controls[0]` as the block-rate fallback when port 0 is unconnected;
- sanitize non-finite frequency to `0 Hz`;
- update `q::phase_iterator` per sample for audio-rate FM;
- update `q::phase_iterator` once per block for constant frequency;
- generate one output sample by applying a stateless waveshape.

The differing part is only the waveshape:

- `SinOscSpec` calls `q::sin`;
- `SawOscSpec` calls `q::saw`;
- `TriOscSpec` calls `q::triangle`.

Unlike `BiquadFilterStateAccess<LPFState>` versus
`BiquadFilterStateAccess<HPFState>`, these specs do not discriminate
distinct `std::variant` alternatives. All three plain oscillators use
the same `OscState`. The spec's `state` function is therefore mostly a
kind-specific assertion-message carrier; the real DSP difference is the
waveshape callable.

The shared `process_phase_oscillator<Spec>` keeps the public wrappers
small:

```cpp
static void process_sinosc(...) noexcept {
  process_phase_oscillator<SinOscSpec>(...);
}
```

Those wrappers are deliberately kept even though the switch could call
the template directly. They are useful note anchors, grep targets, and
consistent with the rest of the runtime node processors.

## Why PulseOsc Is Not In The Same Template

`PulseOsc` shares part of the phase/frequency story, but it has a
different state and one more audio-rate concern:

- `PulseOscState` owns a stateful `q::pulse_osc`;
- width lives on port 2;
- width can be block-latched or audio-rate;
- width must be sanitized into `[0, 1]`;
- `last_width` memoizes the block-rate path.

Forcing `PulseOsc` into the plain phase oscillator helper would make the
helper more complicated and less descriptive. The right abstraction is
not "all oscillators"; it is "plain stateless waveshape oscillators that
share `OscState`."

## Why Templates Should Not Replace The NodeKind Switch

`process_graph` dispatches from runtime `NodeKind` values. That is a
runtime decision driven by graph contents loaded through the C ABI.
Templates cannot replace that decision directly because template
arguments must be known at compile time.

The correct shape is:

```cpp
switch (node.kind) {
case NodeKind::LPF:
  process_lpf(...);       // calls process_biquad_filter<LPFState>
  break;
case NodeKind::SinOsc:
  process_sinosc(...);    // calls process_phase_oscillator<SinOscSpec>
  break;
}
```

The switch remains explicit. Templates only simplify the implementation
behind families whose behavior is already known once the switch arm has
been selected.

## Why Templates Should Not Become A Fused-Kernel Framework

The hand-written fused region kernels are intentionally explicit. Their
contracts include graph shape, output materialization, sink accumulation,
bus behavior, and bit-equivalence expectations. A broad template
framework would make those contracts harder to audit.

The useful shared layer is smaller:

- `drive_oscillator` is shared because the oscillator frequency-drive
  loop is genuinely identical;
- the LPF block-rate latch stays inline in fused saw/LPF kernels because
  it is part of the fused kernel's shape-specific DSP sequence;
- sink behavior stays visible through `SinkAccumulator` and explicit
  kernel bodies.

The rule is: template the repeated inner discipline, not the whole
protocol script.

## Benefits In Tinysynth

Templates are useful here when they provide:

- less repeated DSP code;
- one place for sanitation policy;
- one place for state-preservation policy;
- compile-time specialization instead of virtual dispatch;
- clearer review diffs when a family member changes;
- consistent behavior between plain node processors and fused kernels.

They also make missing cases easier to see. After the biquad factoring,
all four filter kinds call the same processor. After the phase oscillator
factoring, all three plain oscillators call the same driver. A future
change to frequency sanitation or block-latched reconfiguration now has
one obvious home.

## Costs And Failure Modes

Templates are not free. The main costs are:

- compile errors can be harder to read when an implicit contract fails;
- over-general templates can hide behavior that should stay explicit;
- each instantiation can generate code, which may increase binary size;
- a generic assertion can lose important kind-specific information;
- putting large templates in headers can spread rebuild costs and ABI
  surface area.

The current tinysynth templates avoid most of those costs:

- they live inside `rt_graph.cpp`, not in a public header;
- they are `static` helpers with file-local scope;
- public C ABI shapes are unchanged;
- wrappers and notes preserve navigation;
- specializations restore kind-specific diagnostics where needed.

## Practical Rule For Future Use

A future tinysynth template is probably worth it when all of these are
true:

- at least three functions or state types repeat the same skeleton;
- the state lifecycle is the same;
- the input/control ports have the same meaning;
- sanitation policy is the same;
- the only difference is a compile-time type or callable;
- specific diagnostics can still be preserved;
- the resulting note can describe one honest shared contract.

A template is probably not worth it when:

- the variants only look similar but differ in lifecycle or resource
  behavior;
- the generic helper needs flags to recover variant-specific semantics;
- a runtime C ABI distinction gets hidden;
- the code becomes harder to grep from the `NodeKind` switch;
- comments must explain around the abstraction rather than through it.

In short: use templates in tinysynth for small, uniform DSP families.
Do not use them to erase meaningful runtime boundaries.
