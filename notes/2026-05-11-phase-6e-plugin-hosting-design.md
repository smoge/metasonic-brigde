# Phase 6.E — Plugin Hosting (Design)

Date: 2026-05-11
Status: design / contract preflight; no code lands here. Bounds
the first plugin-hosting slice and pins the questions hosting
introduces that the resident-kernel surface in 6.A–6.D didn't
have to face. Mirrors the 6.C / 6.D precedent: bound the new
infrastructure, land one minimal kind that exercises it
end-to-end, then add useful kinds in subsequent series.

This note is deliberately *only* a contract. If anything here
changes during implementation, update this note (the 6.C.3b /
6.C.4 / 6.D precedent stands) rather than letting the doc
drift.

## 0. Anchors

This note assumes the state pinned in
[notes/2026-05-11-state-snapshot-phase-6-complete.md](2026-05-11-state-snapshot-phase-6-complete.md).
The five contracts that snapshot settles are the load-bearing
ones for 6.E:

- **Resource model is bus + buffer**, both integer-keyed and
  disjoint. Anything 6.E introduces that's *not* a bus or
  buffer must add a new field to `ResourceFootprint` and
  rederive precedence from there.
- **Allocation is producer-side, lifecycle is explicit**
  (`allocBuffer` / `retireBuffer` / `collectRetiredBuffer`).
  The audio thread observes resource state through
  acquire-loaded atomics.
- **Single-writer-single-instance for shared writable
  resources** (§6.C.5). 6.E plugins that *write* into a
  shared resource inherit this contract.
- **Declarative latency** via `kindLatency`. Plugins that
  introduce inherent pipeline latency must advertise it,
  same as `KSpectralFreeze`.
- **Counter-confirmed-validation is the standard.** A plugin
  kind that touches shared state ships a diagnostic counter
  alongside it.

6.E reuses the §6.C buffer pool for sample-buffer-style
plugins; it does **not** invent a separate plugin-private
buffer pool.

## 1. What 6.E is and is not

### In scope (this design)

- **One new `NodeKind`: `KStaticPlugin`.** Tag `23` (one past
  `KSpectralFreeze = 22`).
- **Static-library plugin shim, not LV2 / VST / CLAP.** A
  plugin in 6.E is a C struct linked into the runtime at
  build time: a vtable of audio-callback function pointers
  plus a fixed-shape state header. There is no plugin
  *discovery*, no dynamic loading, no plugin manifest, no
  versioning negotiation. The shim exists to *prove the
  hosting contract* without committing to any specific
  third-party plugin API.
- **DSL builder**
  `staticPlugin :: PluginRef -> [Connection] -> SynthM Connection`
  — a registered plugin reference plus an audio-input list.
  Returns a single audio output connection. Multi-output
  plugins are deferred to a later kind.
- **One reference plugin: `Identity`.** A two-input / one-
  output adder shipped in `tinysynth/plugins/identity.cpp`
  whose body is literally `out[i] = in0[i] + in1[i]`. Its
  job is to be the smallest possible *real* plugin: it
  exercises every step of the hosting protocol (lookup,
  configure, init, process, teardown) without any DSP value
  of its own. The first non-trivial plugin is a separate
  follow-up.
- `inferEff (StaticPlugin _ _) = [Pure]`. A v1 static plugin
  declares no shared resource interaction. Plugins that read
  or write buses / buffers are a follow-up that lifts that
  declaration to a per-instance effect (see §3).
- Compile-time rejection of unregistered plugin refs (a
  graph that names a plugin not present in the host's
  registry fails compilation, the same way an unwired audio
  input does).

### Out of scope (do **not** open in this design)

- **Any external plugin API (LV2 / VST3 / CLAP / AU).**
  Plugin hosting historically derails on the external-API
  question; 6.E's first cut is intentionally insulated from
  it. Once `KStaticPlugin` is in place and the contract has
  been exercised, a future series may add a per-API adapter
  kind (`KLv2Plugin`, etc.) that targets the same host
  protocol.
- **Dynamic loading / discovery.** The plugin registry is a
  build-time static vector. Runtime plugin install is a
  separate concern that intersects with hot-swap and is not
  worth opening in v1.
- **Multi-output plugins.** One output port per kind in v1.
  The DSL signature returns a single `Connection`. Stereo
  / multichannel plugins are a follow-up that requires the
  same multi-output decision §6.C deferred for record /
  playback.
- **Plugin-owned UI / GUI.** Plugins are headless. A
  `tinysynth-ui` series is independent and parked until the
  resource and threading contracts are settled.
- **Per-instance plugin parameters via OSC.** Plugins
  expose parameters via `controls[]` exactly like every
  other kind. The §6.B OSC dispatch surface already covers
  control updates; no new ABI is needed.
- **Custom error vocabulary.** Plugins return `int` status
  codes: 0 = OK, non-zero = abort the kernel (emit silence
  for the rest of the block, increment an
  `invalid_plugin_call_count` counter). Rich error types
  (`PluginError` enum, recoverable vs. fatal, error
  callbacks) are a follow-up.
- **MIDI-in plugins.** §6.B's MIDI dispatch is separate;
  routing MIDI to a plugin needs the MIDI-in surface 6.E
  doesn't decide.
- **Audio-rate parameter modulation across the plugin
  boundary.** Plugin parameters in v1 are read once per
  block via a `set_parameter(int param_id, double value)`
  callback at the *start* of `process`. Sample-accurate
  parameter automation is a follow-up that needs a different
  callback shape.

## 2. The real questions hosting introduces

### 2.1 Where plugin state lives

`KStaticPlugin` is a normal `NodeKind` with per-instance
state on the `NodeState` variant:

```cpp
struct StaticPluginState {
  int                              plugin_id   = -1;  // registry index
  std::array<std::byte, kMaxState> opaque_blob{};     // plugin-owned bytes
  long long                        process_call_count = 0;
};
```

`opaque_blob` is a fixed-size byte array; plugins that need
more are rejected at registration time (the plugin's
`state_size_bytes` field is checked against `kMaxState`
during `register_plugin`). v1 picks `kMaxState = 4096`,
sized for the worst case among the reference plugins; the
constant is `constexpr` and changing it is a one-edit knob.

This keeps plugins inside the §4.E worker-dispatch model the
existing kinds use — no allocation, no virtual dispatch into
arbitrary heap-resident objects, no audio-thread
`new`/`delete`. The cost is a hard upper bound on per-plugin
state; the benefit is that the host owns the storage and
allocation timing.

### 2.2 The plugin protocol

A plugin is a `PluginSpec` struct, registered at host build
time:

```cpp
struct PluginSpec {
  const char *name;          // unique stable identifier
  int         state_size_bytes;
  int         audio_in_count;
  int         audio_out_count;   // v1: always 1
  int         control_count;     // host-managed parameter slots

  // Lifecycle callbacks. All non-realtime except 'process'.
  void (*init)(void *state, int sample_rate, int max_frames);
  void (*set_parameter)(void *state, int param_id, double value);
  void (*reset)(void *state);

  // Audio callback. Realtime, non-blocking. Returns 0 on
  // success; non-zero increments invalid_plugin_call_count
  // and the host emits silence for the rest of the block.
  int  (*process)(void *state,
                  int nframes,
                  const float * const *inputs,   // audio_in_count
                  float       * const *outputs,  // audio_out_count
                  const double *parameters);     // control_count
};
```

Constraints documented in the spec header (not enforced
mechanically in v1):

- `process` is realtime, non-blocking, allocation-free, no
  syscalls, no I/O.
- `init` / `set_parameter` / `reset` are called from the
  producer thread.
- `state` is per-instance; the host zero-initializes it
  before the first `init` call.
- `process` may not call back into the host (no synchronous
  hooks).

### 2.3 The plugin registry

A namespace-scope `std::array<PluginSpec, kMaxPlugins>` in
`tinysynth/rt_graph_plugins.cpp`. Plugins register through a
`REGISTER_PLUGIN(name, &spec)` macro at translation-unit
init time. Discovery is build-time: the linked translation
units determine the registry contents. The C ABI surface
adds two read-only entries:

- `int rt_graph_plugin_count();` — registered count.
- `int rt_graph_plugin_find(const char *name);` — index by
  name, or -1.

`KStaticPlugin` carries a `plugin_id` control slot
(`controls[0]`, frozen at instance reset — same §6.C.2
contract as `PlayBufMono.buffer_id`) so the audio thread
never resolves names.

The Haskell side ships a `PluginRef` newtype:

```haskell
newtype PluginRef = PluginRef { pluginName :: String }
```

`compileTemplateGraph` resolves it once via
`c_rt_graph_plugin_find` during loading; an unknown name
fails compile with the same diagnostic shape as a missing
buffer.

### 2.4 Threading and lifecycle

- **Construction** (producer thread):
  `register_plugin` is called at static-init time. The
  registry is immutable from the audio thread's point of
  view.
- **Instance reset** (producer thread): `init` is called
  once per instance, before any audio. `state` is host-
  owned, zero-initialized, then handed to `init`.
- **Per-block** (audio thread): `process` is the only
  callback. The host loops over the plugin's audio inputs,
  passes them as `const float * const *inputs`, and the
  plugin writes into `outputs[0]` for the block.
- **Parameter updates** (producer thread or audio thread
  via the §A.2 realtime control queue):
  `set_parameter` is called between blocks. The audio
  thread never calls `set_parameter` synchronously;
  parameter mutations go through the existing realtime
  queue that already routes `c_rt_graph_realtime_set_control`.
- **Tear-down** (producer thread): plugin state is
  destroyed implicitly when the instance is freed.
  Plugins do not own resources that outlive the instance
  in v1 — that's a 6.E.2+ question (file handles, threads,
  buffer pool slots).

### 2.5 Latency contract

Plugins that buffer samples (e.g., a future FFT plugin)
must advertise their pipeline latency. `PluginSpec` gains
an optional `int latency_samples` field; non-zero values
are surfaced via `kindLatency`-equivalent host-side
metadata so the §6.D latency footprint includes them. The
reference `Identity` plugin reports zero.

Skew reporting (`inputLatencySkews`) already handles
multi-input nodes; plugins inherit it without extra work.

## 3. Resource interaction (ResourceFootprint)

`Identity` and any v1 reference plugin: `[Pure]` — no
shared-resource reads or writes. The same lever the §6.D
spectral kind used to keep the resource model unchanged.

Plugins that *do* read or write buses / buffers in a future
series declare the effects per-instance via a new
`PluginSpec.declared_effects` field that the host translates
to `Eff` annotations at compile time. The host enforces:

- A plugin that declares `BufWrite n` inherits the §6.C.5
  single-writer-single-instance contract automatically (the
  existing polyphony clamp keys on `kindLatency`-style
  predicates; extend `isBufferWriterKind` to recognize the
  plugin kind).
- A plugin that declares `BusWrite` / `BusRead` participates
  in the §4.E live-bus barrier rule unchanged.
- A plugin that declares neither stays `[Pure]`.

This is the contract surface the v1 design pins. The
implementation of the per-instance effect declaration lands
in a follow-up; the v1 `Identity` plugin proves the
plumbing without exercising it.

## 4. Why this kind first

`Identity` is the smallest reference plugin that:

- Exercises the full protocol (register, find, init,
  set_parameter, reset, process).
- Has a non-trivial signature (two inputs, one output)
  that catches single-port mis-wiring.
- Has a trivially testable kernel: `out[i] = in0[i] +
  in1[i]` — easy to assert bit-exactly.
- Reports `latency_samples = 0`, exercising the
  zero-latency path of the latency surface.

The first useful plugin (probably a simple
delay-with-feedback or a soft-clipper) is a separate
follow-up once the plumbing is settled. The §6.C / §6.D
precedent: ship the minimal kind end-to-end, then add useful
kinds.

## 5. The 5 (+1) sites

Same checklist as every other new kind:

| # | File                                | Edit                                                                  |
|---|-------------------------------------|-----------------------------------------------------------------------|
| 1 | `Types.hs`                          | `KStaticPlugin` constructor on `NodeKind`                             |
| 2 | `Types.hs`                          | `kindSpec` row: `KindSpec 23 SampleRate 2 1 "staticPlugin"` (the `Identity` arity; later plugin kinds vary) |
| 3 | `Bridge/Source.hs`                  | `UGen` constructor `StaticPlugin !PluginRef ![Connection]`            |
| 4 | `Bridge/Source.hs`                  | `ugenView` row produced per-plugin from the registered `PluginSpec`'s arities |
| 5 | `Bridge/Source.hs`                  | builder `staticPlugin :: PluginRef -> [Connection] -> SynthM Connection` |
| 6 | `Bridge/Source.hs`                  | `inferEff (StaticPlugin ref _) = pluginEffects ref` (today: `[Pure]` for `Identity`; future-proofed for declared effects) |
| 7 | `Types.hs` (`portInfo`)             | port info derived from the resolved `PluginSpec`'s `audio_in_count`, all `PortSampleAccurate` in v1 |

C++ side (`tinysynth/rt_graph.cpp` + new
`tinysynth/rt_graph_plugins.{cpp,h}` + plugin TUs):

- `NodeKind::StaticPlugin = 23`, `kind_from_tag` row.
- `StaticPluginState` on the `NodeState` variant.
- `configure_spec` row pulls arities from the `PluginSpec`
  registry; `init_node_state` calls the plugin's `init`.
- `process_static_plugin` in `rt_graph.cpp` dispatches via
  the registry: looks up `PluginSpec` by `plugin_id`,
  resolves audio inputs, calls `process`. On non-zero return
  it emits silence and ticks
  `g.invalid_plugin_call_count`.
- New design Note `[Static plugin protocol]` alongside the
  state struct.

ABI additions in `rt_graph.h`:

- `rt_graph_plugin_count`, `rt_graph_plugin_find`.
- `rt_graph_test_plugin_call_count`,
  `rt_graph_test_invalid_plugin_call_count` (mirror the
  spectral / buffer counter pattern).

## 6. Tests

Counter-confirmed-validation discipline. New counters on
`RTGraph`:

- `plugin_call_count` — one tick per `process` call
  (regardless of return).
- `invalid_plugin_call_count` — one tick per non-zero return.

Test group `staticPluginSkeletonTests`:

1. `inferEff produces Pure for Identity`.
2. `kindSpec / portInfo agree with the registered Identity
   spec` — tag 23, audio arity 2, control arity 1, label
   `staticPlugin`.
3. `staticPlugin compiles + dispatches a single block` —
   build a graph with `Identity` summing two `Param` sources,
   render one block, assert output equals sum.
4. `unregistered plugin name fails compile` — DSL-level
   rejection.
5. `plugin_call_count ticks once per block` — render N
   blocks, assert counter == N.
6. `invalid plugin emits silence` — a stub plugin whose
   `process` returns -1; assert audio is zero and
   `invalid_plugin_call_count` ticks.
7. `Identity bit-exact against a hand-rolled Haskell sum` —
   pick a deterministic input pattern, render, compare to
   `zipWith (+)`.
8. `set_parameter is honored between blocks` — render once
   with `gain = 1.0`, then `c_rt_graph_realtime_set_control`
   to bump gain to 2.0, render again, assert the output
   doubled.
9. `latency_samples is surfaced via the latency footprint` —
   register a plugin with `latency_samples = 64`,
   `declaredLatencyFootprint` reports it. (Reference
   `Identity` reports zero; this test uses a second stub
   plugin.)
10. `plugin region is not a Barrier by default` — plugins
    inherit normal scheduling unless they declare bus/buffer
    effects. The schedule classifies a v1 `[Pure]` plugin
    region as a `FreeSegment` candidate.

After all tests pass: total ≈ 600 + 10 = 610 Haskell, 309 + a
small number of new C++ tests for the registry and ABI
entries.

## 7. Implementation slicing

Three commits, each keeping `stack test` green. Same
no-intentionally-red-CI rule.

### Slice 1 — Plugin registry + skeleton kind

- `PluginSpec` struct, `register_plugin`, registry array,
  `rt_graph_plugin_count` / `_find` C ABI.
- `KStaticPlugin` (tag 23) in `NodeKind` / `kindSpec`,
  `PluginRef` newtype, `StaticPlugin` UGen + builder.
- C++ skeleton `process_static_plugin` that emits silence
  and ticks no counters; `StaticPluginState` on the variant.
- Slice-1 tests: registry lookup, kindSpec shape, kind
  loads and renders without crashing.

### Slice 2 — Identity reference plugin

- `tinysynth/plugins/identity.cpp` with the real `process`
  body.
- Real `process_static_plugin` body that dispatches into
  the plugin's vtable.
- `plugin_call_count` / `invalid_plugin_call_count`
  counters + accessors.
- Slice-2 tests: Identity bit-exact, counter math,
  set_parameter, invalid-return silence.

### Slice 3 — Latency surface + ResourceFootprint hook

- `PluginSpec.latency_samples` plumbed into the latency
  footprint (no compensation, exactly like §6.D).
- Stub for `PluginSpec.declared_effects` on the C side
  (descriptive only in v1).
- Slice-3 tests: latency surfacing, Barrier classification
  follows declared effects (zero today, but the predicate
  hook is in place).

After slice 3: `Identity` is shipped, the contract is
exercised, and the next plugin (probably a real
delay-with-feedback) becomes mechanical to add.

## 8. What this does NOT unblock

- **External plugin APIs.** LV2 / VST3 / CLAP / AU each
  need their own adapter kind; the v1 hosting protocol
  exists to be *adapted to* those APIs, not to *be* them.
- **Plugin discovery / dynamic loading.** Build-time
  registry only.
- **Plugin GUIs / `tinysynth-ui`.** Independent series.
- **Multichannel plugins.** Single output per kind in v1;
  multichannel needs the same multi-output decision §6.C
  deferred.
- **Plugin-owned shared resources.** Plugins declare effects
  via the `ResourceFootprint` axis they already inherit;
  no new resource type in 6.E.
- **MIDI-in plugins.** §6.B MIDI dispatch is a separate
  surface.
- **Sample-accurate parameter modulation across the plugin
  boundary.** Block-rate only in v1.

## 9. Open questions / Q-deferrals

Q-1. **`kMaxState` size.** 4096 bytes is a guess sized for
the reference plugins. Real DSP plugins (a 4-tap delay with
feedback, a state-variable filter, a small reverb) easily
fit; an FFT plugin with a 1024-sample window does not. The
right long-term answer is per-plugin `state_size_bytes`
plus a host-side allocation pool sized once at registration.
v1 picks the simple constant; the constant grows if a real
plugin needs more.

Q-2. **`set_parameter` semantics around hot-swap.** If a
producer hot-swaps the graph while plugin parameters are in
flight, the new instance gets the spec's default
parameters. Migration is *not* supported in v1
(`node_kind_supports_state_migration KStaticPlugin = false`,
same as `KSpectralFreeze`). Adding migration requires per-
plugin opt-in via `PluginSpec.supports_state_migration` and
a `migrate_state` callback.

Q-3. **Plugin errors as scheduler signals.** v1 treats a
non-zero `process` return as "emit silence for the block."
It does *not* deactivate the instance. If a use case asks
for "fail-then-release," the host adds a separate kill-on-N-
errors policy.

Q-4. **Audio-rate parameter modulation.** Some plugins
benefit from sample-accurate parameter input (filter cutoff,
envelope amount). The v1 `set_parameter` block-rate path
covers the common case; sample-accurate modulation adds a
parallel `audio_in[]` array of parameter signals that the
plugin reads per-sample. Defer until a real plugin asks.

Q-5. **Plugin ordering across templates.** A `[Pure]`
plugin has no inter-template ordering edges. A plugin that
declares bus/buffer effects inherits the §6.C.4 union
unchanged. Same precedence rules; no new machinery.

Q-6. **Stability of plugin names across builds.** Plugin
names are the only string identifier the runtime accepts.
v1 requires names to be unique within a build. Cross-build
stability is the caller's problem (the same string in two
different builds is the same plugin, by convention). A
content-addressed plugin identity is a future improvement.

## 10. Test plan summary

After slice 3 (~10 new Haskell tests):

- Total: ≈ 610 Haskell, ≈ 315 C++.
- New counters in test surface: `plugin_call_count`,
  `invalid_plugin_call_count`.
- C ABI surface added: registry lookup
  (`rt_graph_plugin_count` / `_find`) plus the two counter
  accessors. No new producer-side entry points for plugin
  registration (it's static / build-time).
- DSL surface added: `PluginRef` newtype, `staticPlugin`
  builder.

The plumbing this design pins is the host-side contract.
The first useful plugin lands in a follow-up; the second
plugin onwards is mechanical to add.
