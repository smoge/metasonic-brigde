# Core hsc3 Naming Compatibility

Date: 2026-05-23

Status: draft note. No code lands on the strength of this note alone.
Review first; any implementation should be a separate narrow slice.

This note records a naming and surface-language direction for the
layer above `MetaSonic.Bridge`: make `MetaSonic.Core` friendly to
users who also work with hsc3 / SuperCollider, without importing
SuperCollider's runtime model into MetaSonic.

The short version:

```text
Compatibility is lexical and authoring-level only.
It is not graph compatibility, server compatibility, or runtime
semantic compatibility.
```


## Related Artifacts

| Topic                       | File                                           | Symbol / anchor                 |
|-----------------------------|------------------------------------------------|---------------------------------|
| Transparent authoring layer | [Authoring.hs](../src/MetaSonic/Authoring.hs)  | module header, `Mono`, `Stereo` |
| Source-level primitive DSL  | [Source.hs](../src/MetaSonic/Bridge/Source.hs) | `sinOsc`, `sawOsc`, `noiseGen`  |
| ABI/runtime kind contract   | [Types.hs](../src/MetaSonic/Types.hs)          | `NodeKind`, `kindSpec`          |
| Current live repertoire     | [Demos.hs](../app/MetaSonic/App/Demos.hs)      | Phase 8b Tier 1 repertoire      |
| Repertoire design           | 2026-05-22-a-live-session-repertoire-design    | Phase 8b demo set proposal      |


## Motivation

The possible `hsc3-performance` side project would be a quick
performance sketchbook. It should help answer musical and operator
questions before MetaSonic has mature authoring sugar for everything:

- what names feel natural while composing;
- what control names, ranges, and CC defaults survive live use;
- what repertoire shapes are worth formalizing;
- what session-shell commands and diagnostics performers actually use.

If MetaSonic's public authoring layer uses a completely different
vocabulary from hsc3 / SuperCollider, sketches become harder to port
mentally. If MetaSonic copies hsc3 too deeply, it risks importing the
wrong model: mutable server node ordering, groups, ad hoc runtime graph
mutation, and rate arguments that do not match MetaSonic's compiler-led
semantics.

The useful middle path is a small `MetaSonic.Core` surface that borrows
familiar names where they are honest, while keeping the existing Bridge,
compiler, session, and C++ runtime contracts intact.


## Current Boundary

`MetaSonic.Authoring` already states the right contract: it elaborates
down to ordinary `SynthGraph` / `TemplateGraph` values and is not a
second compiler. Its helpers emit the same primitive UGens and edges
that `MetaSonic.Bridge.Source` already provides.

That should remain true for any hsc3-friendly naming layer:

- `MetaSonic.Bridge.Source` remains the source-level primitive layer.
- `MetaSonic.Types.kindSpec` remains the canonical per-kind ABI table.
- `tinysynth/rt_graph.*` remains the runtime implementation boundary.
- `MetaSonic.Core` may re-export and alias, but must not introduce a
  second semantic path.

Core names should make graph authoring more comfortable. They should
not change graph meaning.


## Proposed Module Shape

The first design target is a public prelude-style module:

```haskell
module MetaSonic.Core
  ( -- graph basics
    SynthM
  , Connection(..)
  , runSynth
  , tagged

    -- authoring shapes
  , Mono
  , Stereo
  , Channels
  , mono
  , stereo
  , channels
  , mixN
  , pan2

    -- hsc3-friendly source names
  , sinOsc
  , saw
  , pulse
  , tri
  , noise
  , whiteNoise

    -- filters and transforms
  , lpf
  , hpf
  , bpf
  , notch
  , gain
  , add
  , smooth
  , delay

    -- routing
  , out
  , outStereo
  , bus
  , send
  , returnBus

    -- controls
  , control
  , controlWith
  , ccControl
  , controlRange
  , controlName
  ) where
```

This should probably live as a new module rather than changing
`MetaSonic.Bridge.Source` directly. The Bridge names are useful in
compiler, test, and runtime-debug contexts because they say exactly
which primitive kind is being emitted (`sawOsc`, `pulseOsc`,
`noiseGen`). The Core names are for people writing music.

The first implementation slice should keep source aliases raw and
`Connection`-returning, matching `MetaSonic.Bridge.Source`. Users opt
into the `Mono` / `Stereo` authoring helpers explicitly with `mono`,
`stereo`, `pan2`, `outStereo`, and friends. That avoids a slice-2 type
break where `saw` first returns `Connection` and later changes to
`Mono`.


## Naming Direction

Candidate Core names:

| Core name    | Current primitive / helper           | hsc3 / SC-family intent              | Notes |
|--------------|--------------------------------------|--------------------------------------|-------|
| `sinOsc`     | `Bridge.Source.sinOsc`               | `SinOsc`                             | Keep full spelling; `sin` collides with Prelude/math intuition. |
| `saw`        | `Bridge.Source.sawOsc`               | `Saw` / `Saw.ar`                     | Short musical source name. |
| `pulse`      | `Bridge.Source.pulseOsc`             | `Pulse`                              | Keep width argument explicit. |
| `tri`        | `Bridge.Source.triOsc`               | triangle oscillator / `LFTri` idea   | Gray-zone alias: MetaSonic wraps Q's bandlimited `q::triangle_osc`, not SC's `LFTri`; Haddock must say comparable character, not byte-equivalent SC behavior. |
| `whiteNoise` | `Bridge.Source.noiseGen`             | `WhiteNoise`                         | Precise spelling: the C++ state uses `q::white_noise_gen`. |
| `noise`      | `whiteNoise`                         | noise source                         | Friendly generic alias. If pink/brown noise arrive later, keep `whiteNoise` specific. |
| `lpf`        | existing `lpf` / `Authoring.lpfM`    | `LPF`                                | Already aligned. |
| `hpf`        | existing `hpf` / `Authoring.hpfM`    | `HPF`                                | Already aligned. |
| `bpf`        | existing `bpf` / `Authoring.bpfM`    | `BPF`                                | Already aligned. |
| `notch`      | existing `notch` / `Authoring.notchM`| notch / band reject                  | Prefer `notch` over SC-specific `BRF`. |
| `gain`       | existing `gain` / `Authoring.gainM`  | multiply / amp                       | Keep explicit MetaSonic node name. |
| `add`        | existing `add` / `Authoring.addM`    | sum                                  | Keep explicit MetaSonic node name. |
| `smooth`     | existing `smooth` / `Authoring.smoothM` | smoothing / de-zipper             | Keep the MetaSonic name in slice 1 because the parameter is Hz, not SC-style lag time in seconds. |
| `lag`        | deferred                             | `Lag`                                | Do not export as a direct alias in slice 1. A real `lag seconds value` wrapper would need an explicit seconds-to-Hz conversion and tests. |
| `delay`      | `Authoring.delayM` / `delayL`        | delay line                           | Avoid pretending exact `DelayL`/`DelayC` parity. |
| `out`        | existing `out` / `outMono`           | `Out`                                | Already aligned. |

The table is intentionally modest. It avoids names that imply
MetaSonic has copied a specific SuperCollider UGen when the contract is
only similar enough for authoring comfort.


## Example Target Style

Possible Core-style authoring with explicit authoring-shape opt-in:

```haskell
wideDrone = runSynth $ do
  src <- saw 220
  f   <- lpf src 1200 0.7
  s   <- pan2 (mono f) (-0.25)
  outStereo 0 s
```

The value here is not only spelling. The source alias stays close to
hsc3 / SC naming, while `mono`, `pan2`, and `outStereo` show where
Core starts using MetaSonic's transparent authoring helpers.

Current Bridge-style spelling:

```haskell
drone = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc 220 0)
  filtered <- tagged "lpf" (lpf carrier 1200 0.7)
  shaped   <- tagged "gain" (gain filtered 0.2)
  out 0 shaped
```

Possible Core-style authoring:

```haskell
drone = runSynth $ do
  carrier  <- tagged "carrier" (saw 220)
  filtered <- tagged "lpf" (lpf carrier 1200 0.7)
  shaped   <- tagged "gain" (gain filtered 0.2)
  out 0 shaped
```

For slice 1, `saw 220` should mean `sawOsc 220 0` and return
`Connection`. If a later slice wants a `Mono`-returning prelude, make
that a separate module or a deliberately named helper rather than
changing these source-alias types after users have started writing
against them.


## Compatibility With hsc3-performance

`hsc3-performance` can use the same vocabulary to keep sketches
portable by eye:

```text
saw
pulse
tri
noise / whiteNoise
lpf / hpf / bpf / notch
gain
smooth
delay
out
```

Shared names should come with shared performance metadata where useful:

- control names: `pitch`, `cutoff`, `q`, `level`, `mix`, `feedback`;
- conventional MIDI CCs: cutoff `74`, resonance/q `71`, level `7`;
- manifest/repertoire names when a sketch is meant to feed MetaSonic:
  `saw-filter-dark`, `noise-filter-sharp`, etc.;
- ranges in the same unit conventions: cutoff in Hz, q as q, level as
  gain amount, not normalized 0..1 unless the control explicitly says
  it is normalized.

The feedback contract should stay simple:

```text
hsc3-performance tries musical surfaces.
MetaSonic.Core absorbs names and authoring helpers only after the
surface has proved useful.
MetaSonic.Bridge absorbs nothing unless the semantic/runtime contract
is explicitly designed and tested.
```


## Non-Goals

This note does not propose:

- changing `NodeKind` constructors;
- changing `kindSpec` labels or ABI tags;
- changing C++ enum names or runtime dispatch;
- supporting SuperCollider Groups as a runtime primitive;
- copying SC node ordering or `/n_replace` semantics;
- adding `ar` / `kr` arguments to Core helpers before MetaSonic has a
  real semantic reason to expose them;
- adding a `lag` alias whose argument looks like SC lag time but is
  actually MetaSonic's smoother frequency;
- making hsc3 graphs load into MetaSonic;
- making MetaSonic graphs load into scsynth;
- building a general compatibility layer for all hsc3 UGens.

The strong rule: if a name would require runtime behavior MetaSonic
does not have, do not add the name as a comforting lie.


## Test And Evidence Bar

Any implementation should be small and test-first. The contract is
lowering transparency:

1. Each Core alias emits the same primitive graph as its explicit
   Bridge spelling.
2. Any Core helper that wraps `Mono` / `Stereo` / `Channels` preserves
   the existing authoring-layer transparency contract.
3. No alias changes `kindSpec`, tag numbers, control-slot ordering, or
   migration-key behavior.
4. Haddock examples use names that actually compile.

Concrete test shape:

```text
MetaSonic.Spec.Feature.CoreNaming
  saw f produces the same lowered primitive graph as sawOsc f 0
  pulse f w produces the same lowered primitive graph as pulseOsc f 0 w
  tri f produces the same lowered primitive graph as triOsc f 0
  whiteNoise produces the same lowered primitive graph as noiseGen
  noise produces the same lowered primitive graph as whiteNoise
```

These tests should compare emitted primitive shape after the normal
source lowering path, not just successful compilation. Pretty syntax is
not the contract; emitted primitives are.


## First Slice Candidate

Narrow first implementation:

1. Add `src/MetaSonic/Core.hs`.
2. Re-export stable basics from `MetaSonic.Bridge.Source` and
   `MetaSonic.Authoring`.
3. Add only uncontroversial aliases:
   `saw`, `pulse`, `tri`, `noise`, `whiteNoise`.
4. Make those aliases return `Connection`, matching the Bridge source
   constructors.
5. Pin lowering-transparency tests for those aliases.
6. Document `whiteNoise` as the precise source and `noise` as the
   friendly generic alias.
7. Document `tri` as MetaSonic/Q's bandlimited triangle, not exact SC
   `LFTri` behavior.
8. Do not touch manifests, live-session code, runtime tags, or
   existing demos in the same commit.

Second slice, if the first feels right:

1. Add Core-level lifted filter/transform names over `Mono`.
2. Decide whether a separate `Mono`-returning prelude is worth a new
   module, such as `MetaSonic.Core.Authoring`.
3. Update one small demo or documentation example only after the Core
   type style is settled.


## Open Questions

- Should `MetaSonic.Core` hide `Param` by taking `Double` for the
  common source constructors, or should it continue accepting
  `Connection` so modulation remains explicit and uniform?
- Should a later `lag` helper exist at all? If yes, should it expose an
  SC-style time value and convert to MetaSonic's smoother frequency, or
  should it be named differently to avoid implying SC parity?
- Should `delay` expose MetaSonic's required maximum-delay allocation
  parameter directly, or should Core offer a conservative default?
- Should hsc3 compatibility be one module (`MetaSonic.Core`) or two
  modules (`MetaSonic.Core` plus `MetaSonic.Core.SC` or
  `MetaSonic.Core.Authoring`)?

These should be answered by the first implementation review and by
whatever `hsc3-performance` sketches make awkward in practice.
