# SynthGraph And TemplateGraph: Why The Split Exists

Date: 2026-05-21

Status: explanatory note. This is not a new design proposal; it records
the current meaning of `SynthGraph`, `RuntimeGraph`, and `TemplateGraph`
in the checkout after the Phase 8 live-session work.

Primary source material:

- [README.md](../README.md) - current public architecture summary.
- [Source.hs](../src/MetaSonic/Bridge/Source.hs) - `SynthGraph`,
  `SynthM`, `NodeSpec`, and source-level UGen construction.
- [IR.hs](../src/MetaSonic/Bridge/IR.hs) - `GraphIR`, `lowerGraph`,
  rate propagation, and symbolic execution order.
- [Compile.hs](../src/MetaSonic/Bridge/Compile.hs) plus
  [Compile/Types.hs](../src/MetaSonic/Bridge/Compile/Types.hs) -
  dense runtime graph shapes.
- [Templates.hs](../src/MetaSonic/Bridge/Templates.hs) -
  `TemplateGraph`, resource footprints, and inter-template precedence.
- [Manifest live session v0](2026-05-20-b-manifest-live-session-v0.md)
  and [compiler/runtime to live system](2026-05-20-c-compiler-runtime-to-live-system.md)
  - how this split now feeds the live-session layer.

## Short Version

`SynthGraph` and `TemplateGraph` are deliberately not the same thing.

`SynthGraph` is the source-level graph a user or authoring layer builds.
It uses symbolic `NodeID`s, records source UGens, and is still unordered
from the runtime's point of view.

`TemplateGraph` is a compiled plan for one or more named runtime
templates. It contains dense `RuntimeGraph`s, resource footprints, and
an inter-template execution order derived by the compiler.

The split keeps the same project rule intact:

```text
Haskell owns graph meaning. C++ owns execution.
```

The source side can become more musical and convenient, but the runtime
still receives prevalidated dense data. That is the point of the split.

## The Two Pipelines

There are two common routes through the compiler.

Single-template route:

```text
runSynth
  -> SynthGraph
  -> lowerGraph
  -> GraphIR
  -> compileRuntimeGraph
  -> RuntimeGraph
  -> loadRuntimeGraph
  -> C++ runtime template 0
```

Multi-template route:

```text
[(templateName, SynthGraph)]
  -> compileTemplateGraph
       per template:
         SynthGraph -> GraphIR -> RuntimeGraph
       then:
         resource footprints
         inter-template precedence DAG
         topological ordering
  -> TemplateGraph
  -> loadTemplateGraph
  -> C++ runtime templates + instances
```

The multi-template route does not replace the single-template compiler.
It runs that compiler once per named template, then adds a second layer
of scheduling information across templates.

## SynthGraph: Source-Level Meaning

`SynthGraph` lives in `MetaSonic.Bridge.Source`.

It is the result of writing graph-building code with `runSynth` and
source-level builders such as oscillators, filters, gain, bus reads,
bus writes, buffers, and outputs.

In current code, a `SynthGraph` is:

```haskell
data SynthGraph = SynthGraph
  { sgNodes :: Map NodeID NodeSpec
  }
```

Each `NodeSpec` records:

- a symbolic `NodeID`;
- a human-readable node name;
- the source-level `UGen`;
- an optional `MigrationKey` used later by preserving hot-swap.

The important properties are:

- `NodeID` is symbolic and compile-time only.
- Map order is not the runtime execution order.
- The graph can mention source-level conveniences that are later stripped.
- The graph can still fail validation.
- No dense C++ runtime position has been assigned yet.

So `SynthGraph` is close to "what the author wrote", not "what the audio
callback executes."

## GraphIR: Ordered But Still Symbolic

`lowerGraph` turns a `SynthGraph` into `GraphIR`.

This is the first real compiler boundary. The source vocabulary is
stripped and replaced with compiler vocabulary:

- `UGen` becomes `NodeIR`;
- source connections become `InputConn`;
- rate metadata is attached to nodes (`irRate`);
- resource effects are attached to nodes (`irEffects`);
- the optional `MigrationKey` carries through from `NodeSpec.nsMigrationKey`
  into `NodeIR.irMigrationKey`;
- validation and topological sorting have already run.

`GraphIR` stores:

```haskell
data GraphIR = GraphIR
  { giNodes :: ![NodeIR]
  }
```

The list order is execution order *by construction* — there is no
separate `giExecOrder` field to get out of sync. The invariant is
established by `lowerGraph` (which traverses nodes in the order produced
by `validateAndSort`) and must be preserved by every downstream pass.
See `Note [Execution order invariant]` in [IR.hs](../src/MetaSonic/Bridge/IR.hs).

References are still symbolic, though: `NodeIR` names dependencies by
`NodeID`, not by dense runtime `NodeIndex`. That middle state matters.
It lets the compiler reason about rates, effects, regions, bus
footprints, and diagnostics before erasing source identity.

## RuntimeGraph: Dense Single-Template Payload

`compileRuntimeGraph` turns `GraphIR` into a dense `RuntimeGraph`.

This is the decisive `NodeID -> NodeIndex` step. After this point,
symbolic node identity has been resolved into dense runtime positions.

The runtime graph is where MetaSonic commits to C++-friendly data:

- nodes are stored in execution order;
- inputs refer to dense node indices or literals;
- controls have default values;
- regions and kernels are selected;
- bus and buffer footprints are computable from dense runtime nodes;
- optional fusion metadata may be present if the fused compiler route was
  used.

`RuntimeGraph` is still a Haskell value, but it is now shaped for the FFI.
`loadRuntimeGraph` can walk it and emit C ABI calls.

In the single-template path, this is enough: the runtime loads the graph
as template 0 and can play it directly.

## TemplateGraph: Compiled Ensemble Plan

`TemplateGraph` lives in `MetaSonic.Bridge.Templates`.

It is not a bigger `SynthGraph`. It is a compiled plan for a set of named
templates:

```haskell
data TemplateGraph = TemplateGraph
  { tgTemplates  :: ![Template]
  , tgPrecedence :: !(Map TemplateID (Set TemplateID))
  }
```

Each `Template` contains:

- a `TemplateID` (currently `newtype TemplateID = TemplateID Int`);
- a user-provided `tplName`;
- a compiled `RuntimeGraph`;
- a `ResourceFootprint` describing bus and buffer reads/writes.

`tgPrecedence` is **reader-keyed**: `tgPrecedence ! reader` is the set
of templates that must execute before `reader`. A template absent from
the map has no predecessors. The reader-keyed direction matters because
the runtime iterates templates in storage order; the map exists for
diagnostics, future region-DAG-style scheduling, and incremental
recompilation, not as a runtime lookup table.

`compileTemplateGraph :: [(String, SynthGraph)] -> Either String TemplateGraph`
runs four stages:

1. **Per-template lowering.** Each `(name, SynthGraph)` runs through
   `lowerGraph` and `compileRuntimeGraph`. The `TemplateID` is the
   input-list position, *not* the eventual execution position. A
   failure here is reported with the template name to disambiguate.
2. **Name uniqueness**, plus a reject for shared buffer writers:
   same-buffer `BufWrite` from two templates is not given a
   deterministic ordering in v1 (see the §6.C.4 design note for the
   rationale).
3. **Precedence derivation.** Pairwise intersection of writes against
   live reads. O(N²) in template count; N is small in practice
   (typical ensembles < 100 templates).
4. **Topological sort.** DFS with cycle detection over the precedence
   DAG; cycles are reported with the offending template names and the
   bus indices that closed the loop.

Storage order in `tgTemplates` is execution order. The C++ runtime does
not reorder templates. It runs them in the order the Haskell compiler
handed over, processing every live instance of one template before moving
to the next template.

This is the same principle as single-graph scheduling, lifted one level:
source code describes dataflow; the compiler derives execution order; the
runtime executes the order it was given.

## TemplateID And Template Name

`TemplateID` and `tplName` serve different purposes.

`TemplateID` (`newtype TemplateID = TemplateID Int`) is the dense handle
assigned during template compilation. It is set from the input-list
position at stage 1 and is **not** renumbered by the topological sort
in stage 4 — the sort permutes `tgTemplates` storage order, not the IDs
that point into it. That way callers can keep referring to a template
by the ID they constructed it with even if the final execution order
changes. Callers that want a stable, content-addressed identity should
hash the template themselves.

`tplName` is the semantic name chosen by the producer or authoring layer.
It is used for diagnostics and, later, for runtime identity. The hot-swap
path ships template names through the runtime identity ABI so preserving
reloads can reject cases where live instances would migrate into a
different semantic template by accident.

That distinction is important:

- template ID is a compiled handle (input order);
- template name is semantic identity (cross-reload stable);
- execution order is `tgTemplates` storage order (post-sort).

They often line up in simple demos. They are not the same concept.

## Why Not Just One Graph Type?

One graph type would blur four different questions:

1. What did the author write?
2. What is the validated single-template execution order?
3. What dense payload should cross the FFI boundary?
4. How should several templates interact through shared resources?

`SynthGraph` answers the first question.
`GraphIR` answers the second.
`RuntimeGraph` answers the third.
`TemplateGraph` answers the fourth.

Keeping those separate prevents a common failure mode: a source-level
concept accidentally becomes a runtime responsibility.

The runtime should not inspect symbolic names to decide graph order. It
should not search the graph for bus dependencies. It should not decide
whether a template can safely run before another template. By the time
C++ sees the graph, those decisions have already been made.

There is a load-bearing side effect of the dense form on the Haskell
side too: `TemplateGraph` derives a structural `Eq`, and session
hot-swap commits use it as the planned-graph identity check. A
`SynthGraph` could not play that role — two source graphs that elaborate
to the same compiled plan would compare unequal at the source level
(node ordering in the `Map`, source-only sugar, etc.), and the session
adapter would not recognize the post-swap graph as the one the producer
admitted. The compiled form *is* the identity for hot-swap.

## How This Supports Polyphony And Live Sessions

The reason `TemplateGraph` exists is not only "more than one graph." It
is what lets MetaSonic treat compiled graphs as runtime templates.

A template can have instances. A voice template can be instantiated many
times. An FX template can be instantiated once, or whatever policy the
host admits for that template. A shared bus can connect voice templates
to an FX template. The runtime instance table can start, release, and
remove individual voices without rebuilding the graph.

That is why the session layer owns a `TemplateGraph`, not a `SynthGraph`.

Session commands operate on compiled live concepts:

- start this template as a voice;
- release this voice;
- write this control value;
- install this new compiled template graph;
- try preserving state across the install.

The session layer should not rebuild the graph from source every time a
control message arrives. It should operate on the compiled plan that has
already passed validation.

## How This Supports Manifest Reload

The manifest layer adds another contract on top of the same split.

An authoring manifest records the authored surface:

- demo keys;
- template names and roles;
- control names;
- control defaults;
- ranges;
- MIDI CC bindings;
- migration keys and slots.

It does not contain a serialized `SynthGraph` or `TemplateGraph`. The
actual graph is rebuilt from source by the app catalog, and
`planManifestReload` checks that the manifest's declared authoring
surface matches the catalog entry.

The resulting `ManifestReloadPlan` contains the selected `TemplateGraph`
plus the control surface and resource policy needed by the live session.

That shape is why the recent live-session work can combine:

- manifest-aware OSC and MIDI projection;
- range validation;
- preserving reload;
- stopped-audio fallback;
- supervisor recovery;
- operator event rendering.

They all meet at the same compiled plan boundary.

## How This Supports A Future DSL

A future friendlier DSL should not replace `SynthGraph` or
`TemplateGraph`. It should elaborate into them.

For a single instrument, the DSL can produce a `SynthGraph`.

For a multi-template patch, the DSL can produce an authored ensemble,
which lowers to:

```text
[(templateName, SynthGraph)]
```

and then through `compileTemplateGraph`.

For live use, the same DSL can also produce an `AuthoringReport` or
manifest entry so controls, ranges, names, MIDI CCs, and migration keys
stay synchronized with the graph it generated.

That gives a clean layering:

```text
friendly DSL
  -> SynthGraph / authored ensemble
  -> TemplateGraph
  -> manifest reload plan
  -> live session
  -> C++ runtime
```

The future syntax can become more convenient, but the compiler/runtime
boundary remains the same.

## Common Confusions

**"Is TemplateGraph the source graph with templates?"**

No. It is already compiled. Each template inside it contains a
`RuntimeGraph`, not a `SynthGraph`.

**"Does a manifest save the graph?"**

No. The manifest saves the authoring surface. The graph comes from the
catalog/source code and must match the manifest.

**"Can the runtime reorder templates?"**

No. Haskell derives the order. C++ executes it.

**"Does TemplateID equal execution position?"**

Not necessarily. `TemplateID` is assigned from construction order before
topological sorting. `tgTemplates` storage order is execution order.

**"Why not make the source DSL directly build TemplateGraph?"**

Because most authoring constructs are still about one graph. Ensembles
are a layer above that: they gather named `SynthGraph`s, allocate shared
resources, and ask the compiler to derive cross-template order.

## Design Rule

The practical rule is:

```text
Use SynthGraph when authoring one graph.
Use TemplateGraph when running or reloading named templates.
Use ManifestReloadPlan when the live app needs graph + control-surface
metadata together.
```

This rule keeps authoring convenient, compilation explicit, and the
runtime simple.
