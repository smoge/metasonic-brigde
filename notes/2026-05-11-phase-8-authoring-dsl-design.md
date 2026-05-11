# Phase 8 Authoring DSL and Composition Layer Design

Status: draft design note.
Date: 2026-05-11.

## 1. Purpose

Phase 8 is the user-facing counterpart to the compiler/runtime work
from Phases 4-7.

The project already has a solid primitive graph DSL:

- `SynthM` builds a `SynthGraph`.
- `Connection` represents either a constant parameter or an audio edge.
- primitive builders such as `sinOsc`, `gain`, `lpf`, `out`, `busOut`,
  `cc`, `playBufMono`, `spectralFreeze`, and `staticPlugin` lower to
  ordinary `UGen` constructors.
- `compileTemplateGraph` turns named `SynthGraph`s into a
  `TemplateGraph` ordered by resource dataflow.

That is enough to build real patches, but it is still low-level. Users
have to think in mono `Connection`s, explicit repeated branches,
explicit output channels, manual bus numbers, and hand-assembled
template lists.

Phase 8 should add a higher-level authoring and composition layer that
elaborates down to the existing compiler surface. This is not only
syntax sugar. It is the layer that lets practical patches express
musical structure directly while preserving the compiler's ability to
inspect, validate, optimize, and schedule the resulting graph.

## 2. Core Boundary

The boundary is strict:

1. Phase 8 elaborates to ordinary `SynthGraph` and `TemplateGraph`
   inputs.
2. `MetaSonic.Bridge.Source`, `MetaSonic.Bridge.Templates`,
   `MetaSonic.Bridge.Validate`, `MetaSonic.Bridge.IR`, and
   `MetaSonic.Bridge.Compile` remain the semantic authority.
3. Resource ordering, latency metadata, fusion decisions, state
   migration, buffer ownership, plugin metadata, and runtime loading
   still flow through the existing compiler pipeline.
4. The C++ runtime should not learn about Phase 8 constructs.
5. Inspector and survey tools must be able to recover the primitive
   graph clearly enough that the authoring layer does not become
   opaque.

This means Phase 8 is an elaboration layer, not a second compiler.

## 3. Why This Belongs After Phase 7

Phase 7 is about generated fusion and cost modeling. It asks whether
the compiler can generate better runtime execution programs for legal
regions, and whether doing so is measurable.

Phase 8 asks a different question: can authors express larger and more
realistic patches without hand-writing the same boilerplate over and
over?

The two phases are complementary:

- Phase 7 needs realistic graph families to decide which optimizations
  matter.
- Phase 8 makes those graph families easier to write and inspect.
- Phase 8 must still generate normal primitive graphs so Phase 7 can
  analyze them.

If Phase 8 bypassed the compiler, it would weaken the project. If it
feeds the compiler better-shaped graphs, it strengthens it.

## 4. Non-Goals For The First Pass

Do not start Phase 8 with:

- a parser;
- a separate external language;
- a replacement for `SynthM`;
- a separate validation layer;
- a full type-level rate/effect system;
- implicit runtime allocation;
- hidden bus/resource semantics;
- automatic plugin format abstraction;
- true multichannel runtime buffers;
- a promise of sample-accurate control behavior that the runtime does
  not provide.

The first pass should be small enough that every high-level function
can be explained by the primitive nodes it emits.

## 5. Proposed Module Shape

Avoid growing `MetaSonic.Bridge.Source` into a catch-all user API.
Keep it as the primitive layer.

Possible module layout:

```text
src/MetaSonic/Authoring.hs
src/MetaSonic/Authoring/Signal.hs
src/MetaSonic/Authoring/Routing.hs
src/MetaSonic/Authoring/Ensemble.hs
src/MetaSonic/Authoring/Control.hs
```

`MetaSonic.Authoring` can be the public facade that re-exports the
small stable surface.

The lower modules can stay internal or semi-internal until the API
settles.

## 6. Signal Collection Types

The first abstraction should be lightweight wrappers around existing
`Connection`s:

```haskell
newtype Mono = Mono Connection
data Stereo = Stereo Connection Connection
newtype Channels = Channels [Connection]
```

These are authoring-level shapes, not runtime channel buffers. A
`Stereo` value still lowers to two mono primitive paths. A `Channels`
value still lowers to a list of mono primitive paths.

Open design point: whether `Channels` should use `[Connection]` or
`NonEmpty Connection`.

Recommendation for v1:

- use a simple list-backed `Channels` type;
- expose smart constructors;
- make empty-channel behavior explicit per function;
- consider `NonEmpty` later if the API starts tripping on empty mixes.

Useful first helpers:

```haskell
mono          :: Connection -> Mono
stereo        :: Connection -> Connection -> Stereo
channels      :: [Connection] -> Channels
duplicate     :: Int -> Mono -> Channels
mapChannels   :: (Connection -> SynthM Connection) -> Channels -> SynthM Channels
zipChannelsWith
              :: (Connection -> Connection -> SynthM Connection)
              -> Channels -> Channels -> SynthM Channels
sumChannels   :: Channels -> SynthM Mono
```

Keep the first surface explicit. Avoid clever typeclass overloading
until the desired call shapes are visible from real patches.

## 7. Multichannel Expansion Rules

The most important design question is how channel shapes combine.

Recommended v1 rules:

1. Unary operations map channel-wise.

   Example: filtering a stereo signal emits one filter per channel.

2. Binary operations require matching channel counts, unless the user
   explicitly broadcasts.

   Do not silently broadcast every mono signal into every shape. It is
   convenient, but it can hide mistakes.

3. Provide explicit broadcast helpers.

   Examples:

   ```haskell
   broadcastMono :: Int -> Mono -> Channels
   gainStereo    :: Stereo -> Connection -> SynthM Stereo
   gainChannels  :: Channels -> Connection -> SynthM Channels
   ```

4. Preserve deterministic construction order.

   Lowering should emit nodes in the same order every run. This keeps
   dense indices, survey rows, and tests stable.

5. Keep summing order explicit.

   Floating-point addition is not associative. A helper such as
   `mixN` should document whether it emits a left fold or a balanced
   tree. The first implementation should prefer stable, obvious
   ordering over clever balancing.

## 8. Lifted Primitive Surface

The first lifted operations should cover common musical work:

```haskell
gainM       :: Mono -> Connection -> SynthM Mono
gainS       :: Stereo -> Connection -> SynthM Stereo
gainC       :: Channels -> Connection -> SynthM Channels

addM        :: Mono -> Mono -> SynthM Mono
addS        :: Stereo -> Stereo -> SynthM Stereo
addC        :: Channels -> Channels -> SynthM Channels

lpfM        :: Mono -> Connection -> Connection -> SynthM Mono
lpfS        :: Stereo -> Connection -> Connection -> SynthM Stereo
lpfC        :: Channels -> Connection -> Connection -> SynthM Channels

outStereo   :: Int -> Stereo -> SynthM ()
outChannels :: Int -> Channels -> SynthM ()
```

The exact names can change. The important part is the lowering
contract:

- every channel maps to ordinary primitive builders;
- every emitted node remains visible in the resulting `SynthGraph`;
- control defaults and audio edges use the same `Connection`
  semantics as the primitive DSL;
- existing validation catches bad graphs.

Do not add lifted wrappers for every UGen immediately. Add the common
ones first, then let actual patches pull in more.

## 9. Panning, Mixing, And Routing

Authoring helpers should remove routine boilerplate, but they must not
hide resource behavior.

Candidate helpers:

```haskell
mixN
pan2Const
pan2Linear
balance
spread
send
returnBus
stereoOut
```

Important details:

- `pan2Const` can use compile-time gain constants.
- Dynamic equal-power panning is not available without additional DSP
  math primitives. Do not pretend it exists.
- `pan2Linear` can be built from `Gain` and `Add`, but it should
  document that it does not clamp and is not equal-power.
- `send` / `returnBus` should make bus allocation visible through
  metadata or an inspector view.
- If helpers allocate bus numbers, allocation must be deterministic.

The compiler already derives bus ordering from `BusFootprint`.
Phase 8 must preserve that visibility.

## 10. Template And Ensemble Builders

The primitive template API expects a list:

```haskell
[(String, SynthGraph)]
```

Phase 8 can offer a clearer authoring layer:

```haskell
ensemble $ do
  voice "bass" ...
  voice "pad" ...
  fx "return" ...
```

This should lower to the existing input for `compileTemplateGraph`.
The value is authoring clarity:

- stable template names;
- deterministic bus allocation;
- explicit role labels such as voice/fx/control;
- less hand-written send/return plumbing;
- easier survey and inspector output.

Open design point: whether the ensemble builder should return only
`[(String, SynthGraph)]` or a richer value with authoring metadata.

Recommendation:

```haskell
data AuthoredEnsemble = AuthoredEnsemble
  { aeTemplates :: [(String, SynthGraph)]
  , aeMetadata  :: AuthoringMetadata
  }
```

`aeTemplates` feeds `compileTemplateGraph`. `aeMetadata` feeds docs,
inspectors, tests, and external mapping tools. The compiler should not
depend on the metadata for correctness.

## 11. Named Controls And External Mapping

The current `cc` builder already records MIDI CC bindings and inserts
`Smooth` at the control ingress. That is a good primitive. Phase 8
should promote controls into named authoring objects:

```haskell
control "cutoff" 1200.0 (Range 40.0 12000.0)
ccControl 74 "brightness" 1200.0 (Range 40.0 12000.0)
oscControl "/voice/cutoff" "cutoff" 1200.0 (Range 40.0 12000.0)
```

Likely metadata:

- human name;
- default;
- range;
- smoothing policy;
- MIDI CC number, if any;
- OSC address, if any;
- target node and control slot after lowering;
- migration key, if the control-bearing node should retain state
  across swaps.

The external-control implementation stays in the existing MIDI/OSC
surface. Phase 8 makes control definitions easier to write and easier
to inspect.

## 12. Naming And Migration Keys

High-level helpers will emit extra nodes. If those nodes are unnamed or
unstable, hot-swap state migration and inspector output become harder
to reason about.

Phase 8 should define naming rules early:

- generated node names should include a stable construct prefix;
- repeated generated nodes should use deterministic suffixes;
- helper-generated stateful nodes may need migration keys;
- user-provided names should be preserved where possible;
- generated keys should not collide silently.

Example:

```text
lead.pan.leftGain
lead.pan.rightGain
lead.filter.left
lead.filter.right
```

The exact naming format can change, but stability matters.

## 13. Lowering Transparency

Every high-level construct should have a way to answer:

```text
What primitive graph did this produce?
```

The first version can rely on tests and existing inspector output.
Later versions can expose authoring metadata to show:

- authoring construct;
- generated node names;
- generated template names;
- generated bus names and numeric ids;
- generated control mappings.

This is critical. An opaque DSL would fight the project's core idea:
compile-time visibility.

## 14. Tests

Testing should focus on lowering, not audio DSP.

First tests:

1. `Stereo` construction emits no nodes by itself.
2. `gainS` emits two `KGain` nodes with stable names/order.
3. `outStereo 0` emits `Out 0` and `Out 1`.
4. `mixN` emits a deterministic `Add` chain.
5. channel-count mismatch is rejected or handled explicitly.
6. `send` / `returnBus` lowers to visible `BusOut` / `BusIn`.
7. an ensemble lowers to the same shape expected by
   `compileTemplateGraph`.
8. named controls preserve stable post-compile lookup.

Avoid testing only pretty API behavior. Pin the primitive graph shape,
because that is the contract downstream compiler passes consume.

## 15. First Demo Target

The first migrated demo should be small and obviously improved by the
new layer.

Good candidates:

- a stereo detuned saw patch;
- a stereo filtered noise patch;
- a send/return ensemble with one voice template and one fx template;
- a simple MIDI-controlled stereo voice.

The demo should prove that Phase 8 reduces boilerplate without hiding
the generated graph from surveys or inspectors.

## 16. Risks

### Hidden graph bloat

High-level helpers may generate many nodes. Mitigation: add tests and
survey rows that show the emitted node count.

### Implicit bus allocation

Automatic routing can obscure resource edges. Mitigation: deterministic
allocation plus metadata/inspector output.

### Typeclass cleverness

Overloaded APIs can become pleasant for demos and painful for
debugging. Mitigation: start with explicit functions, add typeclasses
only after repeated call patterns are stable.

### Accidental second compiler

If Phase 8 starts validating effects, ordering templates, or hiding
runtime decisions, it duplicates the real compiler. Mitigation: always
lower to the existing pipeline and let existing validation decide.

### Overpromising dynamic DSP

Some high-level music terms, such as equal-power dynamic panning, need
DSP primitives the project may not have yet. Mitigation: name the
approximation clearly or defer the helper.

## 17. Recommended First Implementation Series

1. Add the Phase 8 design note and roadmap link.
2. Add module scaffolding for `MetaSonic.Authoring`.
3. Add `Mono`, `Stereo`, `Channels`, and explicit constructors.
4. Add `gainM` / `gainS`, `addM` / `addS`, `outStereo`, and tests.
5. Add `mixN` with deterministic lowering and tests.
6. Rewrite one small demo using the authoring layer.
7. Add simple routing helpers only after the signal wrappers settle.
8. Add named-control metadata once OSC/MIDI naming requirements are
   clearer.

## 18. Recommendation

Phase 8 should be an authoring and composition layer, not merely
syntax sugar.

It should make common musical structures shorter and safer to write,
while preserving the project invariant that Haskell compiles explicit
graphs and C++ executes dense, pre-resolved plans.

The first implementation should be intentionally modest: signal
collection wrappers, lifted gain/add/output helpers, deterministic
lowering tests, and one migrated demo. That will reveal whether the API
shape is right before the project commits to larger routing, ensemble,
and named-control abstractions.
