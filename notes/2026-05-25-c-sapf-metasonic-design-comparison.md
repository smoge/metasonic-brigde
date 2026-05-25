# SAPF And MetaSonic Design Comparison

Date: 2026-05-25

Status: design reference for future work. This note replaces the stale
March SAPF drafts as the current comparison artifact. It does not approve
any code change by itself; each implementation slice still needs its own
small design/test bar.

Short version:

```text
SAPF is a model for musical authoring semantics.
It is not a runtime model for MetaSonic to copy.

The SAPF ideas worth adapting belong above the bridge, where they can
elaborate into existing SynthGraph, TemplateGraph, Pattern, SessionCommand,
and tinysynth contracts.
```

## Related Artifacts

| Topic                         | File / source                                           | Symbol / anchor                                      |
|-------------------------------|---------------------------------------------------------|------------------------------------------------------|
| Stale SAPF draft              | [2026-03-27-sapf-part-2-draft.md](../drafts/2026-03-27-sapf-part-2-draft.md) | unfinished March draft                               |
| Fuller stale SAPF draft       | [sapf4.md](../drafts/sapf4.md)                         | March design comparison                              |
| Public architecture summary   | [README.md](../README.md)                              | Authoring layer, session preparation APIs            |
| Roadmap current state         | [ROADMAP.md](../ROADMAP.md)                            | Phase 2, Phase 6.A, Phase 8.E/F                      |
| Transparent authoring layer   | [Authoring.hs](../src/MetaSonic/Authoring.hs)          | `AuthoredEnsemble`, `NamedControl`                   |
| Pattern/event producer layer  | [Pattern.hs](../src/MetaSonic/Pattern.hs)              | `Pattern`, `PatternEvent`                            |
| Session command bridge        | [Command.hs](../src/MetaSonic/Session/Command.hs)      | `SessionCommand`, `fromPatternEvent`                 |
| Pattern producer bridge       | [PatternProducer.hs](../src/MetaSonic/Session/PatternProducer.hs) | `enqueuePatternBlock`                         |
| Template compiler             | [Templates.hs](../src/MetaSonic/Bridge/Templates.hs)   | `compileTemplateGraph`, `TemplateGraph`              |
| Rate/effect metadata          | [Types.hs](../src/MetaSonic/Types.hs)                  | `Rate`, `Eff`, `PortConsumptionRate`, `kindSpec`     |
| Rate propagation              | [IR.hs](../src/MetaSonic/Bridge/IR.hs)                 | `propagateRates`                                     |
| Resource ordering             | [Validate.hs](../src/MetaSonic/Bridge/Validate.hs)     | `Effect-induced edges (E_r)`                         |
| Source-level feedback         | [Source.hs](../src/MetaSonic/Bridge/Source.hs)         | `BusInDelayed`, `Delay`                              |
| Core naming direction         | [2026-05-23-a-core-hsc3-naming-compatibility.md](2026-05-23-a-core-hsc3-naming-compatibility.md) | `MetaSonic.Core` facade              |
| SAPF repository               | [SAPF repository](https://github.com/lfnoise/sapf)      | source tree                                          |
| SAPF README                   | [README.txt](https://raw.githubusercontent.com/lfnoise/sapf/main/README.txt) | language model and type summary       |
| SAPF examples                 | [sapf-examples.txt](https://raw.githubusercontent.com/lfnoise/sapf/main/sapf-examples.txt) | forms, `@`, `ola`, `oltx`, `splay`    |

## What SAPF Is Teaching

SAPF describes itself as "sound as pure form": a mostly functional,
stack-based, postfix interpreter for creating and transforming sound. Its
README says it represents audio and control events with lazy, possibly
infinite sequences, aiming to do for lazy sequences what APL does for
arrays: high-level mapping, scanning, and reduction over whole
structures. The same README says nearly all programmer-visible data types
are immutable, with mutation isolated in `Ref`.

Those facts matter because they point to a musical authoring style:

- a sound can be described as a `Form`, a dictionary with inheritance;
- lists act as streams and signals;
- scalar-looking operations lift over structures;
- `@` asks the next function to operate over each value at a deeper
  structural level;
- texture helpers such as `ola`, `oltx`, and `splay` turn short sound
  descriptions into overlapping populations;
- mutation is explicit and rare.

The SAPF examples make the authoring lesson concrete. `analog_bubbles`
can be written as a form with named fields and an `out` function, then
reused by overriding fields. The `busytone` example is the more direct
texture precedent: it overrides fields with random streams and uses `@`
plus `ola` to turn one sound definition into a stream of overlapping
stereo events.

The useful lesson is not "copy SAPF syntax." The useful lesson is:

```text
Small musical concepts should compose into rich sound without requiring
the user to manage graph plumbing, instance allocation, or scheduling
mechanics at every step.
```

## Current MetaSonic State

The old March drafts treated several pieces as future work. In the
current checkout, they are no longer future:

- `MetaDef` / `GraphInstance` and multi-instance runtime support have
  landed.
- `TemplateGraph` is the compiled multi-template plan. It owns template
  ordering, resource footprints, and inter-template precedence.
- `Eff` annotations are real for buses and buffers. They drive
  intragraph resource ordering and inter-template precedence.
- `BusInDelayed` and `Delay` are already explicit feedback/delay
  primitives. Feedback through a delayed bus read is schedulable because
  it closes across the previous-block snapshot, not through a live
  same-block edge.
- `propagateRates` is implemented and coherent. The remaining rate
  problem is not "add rate propagation"; it is sample-accurate connected
  controls and the per-port consumption/block-rate execution story.
- The `Pattern` layer is a deterministic Haskell-side producer of timed
  symbolic events.
- `SessionCommand`, `PatternProducer`, queue/fan-in, OSC/MIDI/UI
  producers, and preserving hot-swap policy have all moved MetaSonic
  beyond "one graph runs forever."
- `MetaSonic.Authoring` already provides transparent channel helpers,
  routing helpers, ensemble builders, and named controls that elaborate
  back to ordinary `SynthGraph` / `TemplateGraph` inputs.

So the updated question is not "how can SAPF force MetaSonic to grow a
temporal layer?" The current question is:

```text
How should SAPF-like authoring ideas sit above the existing compiled
graph/session substrate without weakening the substrate?
```

## Layer Rule

SAPF ideas should land at the highest layer that can preserve the current
runtime contract:

```text
Compile pipeline (per graph):
  MetaSonic.Core / authoring helpers
    -> SynthGraph / [(String, SynthGraph)]
    -> GraphIR / RuntimeGraph / TemplateGraph

Runtime drivers (alongside the compiled artifact):
  Pattern / SessionCommand / producer fan-in
    -> session owner / RTGraphAdapter
    -> tinysynth dense runtime
```

The bottom block is not a continuation of the compile pipeline. `Pattern`
and `SessionCommand` are runtime-side producers that drive an
already-compiled `TemplateGraph` / `MetaDef` through the session owner.
They are upstream of `tinysynth` in time, but not in compilation.

The lower the layer, the stronger the proof obligation. A name alias in
`MetaSonic.Core` only needs a lowering transparency test. A new
`NodeKind` needs the full Haskell/C++ tag, arity, rate, effect, port,
runtime, and DSP test path. A new realtime runtime policy needs
allocation and audio-thread evidence.

A general invariant cuts across all of these: authoring metadata must
not leak into `tinysynth` as a symbolic runtime lookup. Whatever a
higher layer records about names, forms, axes, or textures is
authoring/diagnostic information; the dense runtime continues to
receive only prevalidated graph and schedule data.

That leaves two valid authoring outputs:

- finite graph/template artifacts, when the authoring helper describes
  sound structure;
- finite pattern/session events, when the authoring helper describes
  temporal behavior.

If a proposed SAPF-inspired helper cannot say which of those it
produces, the design is still too vague for implementation.

This is the main design comparison:

| SAPF idea | MetaSonic analogue today | Adaptation rule |
|-----------|--------------------------|-----------------|
| Forms with inheritance | `AuthoredEnsemble`, manifests, named controls, future `MetaSonic.Core` patch forms | Prefer functions/records/builders over inheritance. Preserve transparent lowering. |
| Lazy sequences | `Pattern`, deterministic event ranges, producer queues | Authoring may be lazy/symbolic; ABI/runtime inputs must be finite and explicit. |
| Automatic mapping / `@` | `Mono`/`Stereo`/`Channels`, lifted UGen helpers, possible future voice/event/control lifts | Keep axes explicit: channel, voice, event, control. Do not collapse them into one generic list model. |
| Scan/reduce | `mixN`, `sumChannels`, fusion surveys, scheduler metadata | Start with source combinators. Add skeleton metadata only when optimization evidence justifies it. |
| Texture helpers (`ola`, `oltx`, `splay`) | `Pattern` corpus, `PatternProducer`, session commands | Future texture combinators should emit deterministic `Pattern`/session events, not runtime-interpreted lazy lists. |
| Mostly immutable data plus `Ref` | compiled graphs, immutable template specs, isolated runtime/session mutation | Keep mutation behind `RTGraph`, `SessionOwner`, producer state, and realtime queues. |
| Signal/value/rate distinctions | `Rate`, `propagateRates`, `PortConsumptionRate`, block-latched ports | Continue the per-port/sample-accuracy work; do not rewrite `SynthGraph` around type-indexed rates yet. |

## Forms: Patch Families Above Templates

SAPF forms are useful because they let a sound definition carry named
parameters and be specialized by override. MetaSonic already has the
compiled half of that idea:

- `TemplateGraph` is the compiled ensemble plan.
- `MetaDef` is the runtime template.
- `GraphInstance` is the runtime instance state.
- `NamedControlMetadata` records control names/ranges/CC bindings.
- manifests and reload plans already connect named templates and
  controls to session/reload behavior.

The missing part is a pleasant authoring-level patch-form vocabulary.
This belongs in `MetaSonic.Core` or above `MetaSonic.Authoring`, not in
the bridge compiler.

Conservative first shape:

```haskell
data PatchForm a = PatchForm
  { pfName     :: String
  , pfDefaults :: a
  , pfBuild    :: a -> SynthGraph
  }
```

Variants should start as functions:

```haskell
bright :: FilterPatch -> FilterPatch
bright p = p { fpCutoff = 8000.0 }
```

This is less general than SAPF's open form inheritance, but it matches
the current project bias: simple Haskell functions, transparent
elaboration, and no new runtime shape. Open dictionaries or row-typed
forms can wait until real patches show that closed records are blocking
composition.

Note d sketches a parallel sub-voice shape that returns
`SynthM Auth.Mono` instead of `SynthGraph` — useful when the patch form
describes a voice that gets mixed into a larger graph rather than a
top-level graph. The two shapes coexist; either can be the first slice.

Test bar for a first patch-form slice:

- a variant changes only the expected control defaults;
- the emitted `SynthGraph` or `TemplateGraph` is structurally equivalent
  to a hand-written graph;
- generated reports/manifests carry the expected names/ranges;
- no metadata is embedded in `SynthGraph` / `TemplateGraph` unless a
  separate design note reopens that boundary.

## Mapping: Axes, Not Lists

SAPF's mapping and `@` operator encourage thinking over structures
instead of looping by hand. MetaSonic should keep that authoring lesson
but avoid copying the implicitness.

The important distinction is axis meaning:

- channel expansion: one signal becomes stereo or N channels;
- voice expansion: one template becomes many live instances;
- event expansion: one gesture becomes a scheduled stream;
- control expansion: one control description targets several runtime
  addresses.

Those axes lower differently. A reverb should not be duplicated per
voice by accident. A per-note envelope should not be shared across all
voices by accident. A stereo pair is not a voice bank. A list of future
events is not an audio bus.

Current state:

- channel expansion has a home in `MetaSonic.Authoring`;
- voice expansion is partly runtime/session work through templates,
  instances, MIDI, and session commands;
- event expansion exists at the `Pattern`/`PatternProducer` level;
- control expansion exists in pieces through named controls, OSC/MIDI
  producers, and fan-in.

Near-term rule:

```text
Prefer explicit helpers named by axis before adding a generic typed
lifting abstraction.
```

Examples:

```haskell
duplicateChannels
voiceBank
overlapEvents
fanOutControl
```

A single `Liftable axis` abstraction might be attractive later, but the
first implementation should keep lowering visible. This project has
benefited from explicit, testable surfaces; generic type machinery should
arrive only after the common shapes are known.

## Texture: SAPF's Strongest Authoring Lesson

SAPF's texture helpers are the strongest signal for future
`MetaSonic.Core` work. They make event populations easy:

```text
one sound definition
  -> randomized field streams
  -> overlap/crossfade/spread
  -> a texture
```

MetaSonic already has the lower substrate for this:

- `Pattern` can produce timed symbolic `PatternEvent` values.
- `PatternProducer` can expand one sample range and enqueue the
  corresponding `SessionCommand`s.
- the session owner can admit voice starts, voice stops, control writes,
  and hot-swap commands.
- MIDI and OSC producers already share the fan-in policy space.

The future work is not "invent events." It is ergonomic texture
authoring over the existing event/session layer.

Candidate helpers:

```haskell
overlap
  :: TextureOptions
  -> PatchForm a
  -> Stream a
  -> Pattern

stagger
  :: SamplePos
  -> [PatternEvent]
  -> Pattern

swarm
  :: Int
  -> Seed
  -> (Int -> a)
  -> PatchForm a
  -> Pattern
```

`Stream a` and `Seed` here are placeholders, not existing types. The
first real slice can settle them as `[a]` plus a deterministic seed
newtype, or as a thin lazy-generator type — whichever shape keeps
expansion finite and reproducible. The point of the sketch is the
*signature shape*, not the exact spelling.

Design constraints:

- texture helpers must produce deterministic `Pattern` output for a
  fixed seed/range;
- no lazy list is evaluated on the audio thread;
- compile errors surface before realtime use;
- queue full/backlog behavior stays in `PatternProducer`/fan-in, not in
  the texture helper;
- realtime voice allocation policy stays where the session/runtime layer
  already owns it.

Test bar:

- `expandPattern` output is byte-identical for a fixed seed and range;
- generated templates compile through `compileTemplateGraph`;
- a texture row appears in corpus/survey output without special cases;
- a `PatternEvent` round-trip through `fromPatternEvent` and the session
  owner remains covered.

## Scan, Reduce, And Skeletons

The March drafts overreached when they implied the IR could simply "see"
`mconcat` or `Category` laws. In the current compiler, the IR sees
primitive nodes, edges, effects, rates, regions, and dense runtime
metadata. It does not automatically know that a source expression was a
scan, fold, bank, or texture unless an authoring layer records that
structure somewhere.

The safe first rule is:

```text
Use source-level combinators first. Add skeleton annotations only when a
measured compiler optimization needs them.
```

Good source-level starts:

- `mixN` and `sumChannels` for reduction-like mixing;
- `chain` helpers for serial construction;
- explicit `voiceBank` helpers that produce named templates or pattern
  starts;
- texture helpers that produce `Pattern`.

Compiler-visible skeleton metadata is a later question. It is justified
only if it unlocks a concrete optimization such as template
deduplication, generated fusion selection, or a scheduler improvement
that the existing graph/region metadata cannot express.

Reopen criteria:

- a source combinator emits many structurally repeated graphs;
- surveys show a recurring missed optimization;
- the optimization cannot be recovered from existing `GraphIR`,
  `RuntimeGraph`, `ResourceFootprint`, or `Pattern` data;
- the proposed metadata does not leak into `tinysynth` as a symbolic
  runtime lookup.

## Rate: Do Not Reopen The Wrong Problem

SAPF's signal/value distinctions reinforce the importance of temporal
semantics. They do not imply that MetaSonic should rewrite the current
bridge around type-indexed rates.

Current state:

- `kindSpec` gives each kind an intrinsic rate floor.
- `propagateRates` raises each node to the join of its floor and input
  rates.
- `RuntimeNode` preserves descriptive rate metadata.
- `PortConsumptionRate` records how each destination port consumes its
  input.
- the unsolved practical gap is sample-accurate connected controls and
  whether/when a block-rate execution path is worth enabling.

So the future work should stay focused:

- sample-accurate connected control inputs where the musical case
  demands it;
- continued per-port opportunity surveys;
- no broad type-indexed `SynthGraph` rewrite until a separate
  `MetaSonic.Core` experiment proves that users benefit.

Type-indexed rate APIs may still be a good future `MetaSonic.Core`
research direction. They should not replace the working bridge
discipline without evidence.

## Effects And Mutation

SAPF's mostly immutable data model maps cleanly to MetaSonic's strongest
current design habit: construction and validation happen before the
runtime hot path, and mutation is isolated behind explicit owners.

MetaSonic should keep that discipline:

- source/authoring structures are ordinary Haskell values;
- `SynthGraph`, `GraphIR`, `RuntimeGraph`, and `TemplateGraph` are
  compiled artifacts;
- resource effects are explicit `Eff` annotations;
- session mutation is serialized through `SessionOwner`, fan-in, and
  producer state;
- runtime mutation is constrained to realtime queues, prewarmed
  instances, control writes, preserving swap state, and explicit
  lifecycle operations.

Do not import a "live interpreter" mental model into `tinysynth`. A
future live authoring shell may be interactive, but it should still
compile or prepare finite artifacts before the audio thread consumes
them.

## Explicit Non-Goals

This note does not propose:

- porting SAPF syntax to Haskell;
- adding a stack/postfix interpreter to MetaSonic;
- evaluating lazy sequences on the audio thread;
- replacing `SynthM` with a free monad;
- replacing `SynthGraph` with a type-indexed graph API;
- embedding authoring metadata into `SynthGraph` or `TemplateGraph`;
- adding a new C++ runtime scheduling language;
- broadening `tinysynth` beyond dense, prevalidated runtime data.

Any of those could be reopened later, but not as a side effect of
"learning from SAPF."

## Practical Future Slices

Ordered by likely value and low disruption:

1. **Core patch-form experiment.** Add a small `MetaSonic.Core` or
   adjacent module for patch forms as plain Haskell functions/records
   that elaborate to existing authoring/bridge values. This is the
   first *musical authoring* slice; note d's shallow Core facade can
   land first if the immediate task is public API naming.
2. **Texture combinator prototype.** Build `overlap`/`swarm`-style
   helpers that produce deterministic `Pattern` rows and add one corpus
   fixture.
3. **Axis-specific lifting helpers.** Extend authoring with explicit
   helpers for voice/event/control axes, keeping channel helpers as the
   model for transparent lowering.
4. **Authoring reports for texture/forms.** Surface enough diagnostic
   metadata for humans without making the compiler depend on it.
5. **Skeleton reopen only with survey evidence.** Add annotations or a
   skeleton IR layer only if generated-fusion, template deduplication, or
   scheduling evidence shows the existing graph metadata is insufficient.
6. **Rate/control follow-through.** Continue the sample-accurate
   connected-control and per-port consumption path; keep type-indexed
   rates as a Core-level research topic, not a bridge prerequisite.

## Reference Thesis

SAPF shows how much musical reach comes from a small number of
composable authoring concepts: forms, structural mapping, streams,
scan/reduce, texture helpers, and isolated mutation.

MetaSonic's answer should not be to become SAPF. MetaSonic's answer is
to let a future `MetaSonic.Core` offer similarly compact musical
concepts while the bridge and runtime keep doing what they already do
well: validate, lower, schedule, compile, and execute dense audio
artifacts with explicit resource and lifecycle semantics.
