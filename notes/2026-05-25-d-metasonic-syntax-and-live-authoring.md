# MetaSonic Syntax And Live Authoring Direction

Date: 2026-05-25

Status: design reference for future work. This note supersedes the
stale `drafts/metasonic-syntax.md` sketch as the current syntax and
live-authoring reference. It does not approve any implementation by
itself; each slice below still needs a narrow test bar.

Short version:

```text
The old draft had the right product instinct:
make MetaSonic feel like ordinary Haskell for musical authoring.

The old draft had the wrong implementation center:
do not add a second NodeExpr/Sig compiler or a hint-first runtime path.

Current direction:
MetaSonic.Core / Authoring syntax
  -> SynthM / SynthGraph / TemplateGraph
  -> Pattern / SessionCommand / producer fan-in
  -> RTGraph adapter / tinysynth runtime
```

The short rule: a friendly syntax layer may reduce authoring friction,
but every path must still end in either a finite compiled graph/template
artifact or a finite session/pattern command stream.

## Related Artifacts

| Topic                         | File / source                                           | Symbol / anchor                                      |
|-------------------------------|---------------------------------------------------------|------------------------------------------------------|
| Stale syntax draft            | [metasonic-syntax.md](../drafts/metasonic-syntax.md)    | `NodeExpr`, `Sig`, `hint` sketch                     |
| Phase 8 authoring design      | [2026-05-11-l-phase-8-authoring-dsl-design.md](2026-05-11-l-phase-8-authoring-dsl-design.md) | elaboration-only authoring layer |
| Core naming direction         | [2026-05-23-a-core-hsc3-naming-compatibility.md](2026-05-23-a-core-hsc3-naming-compatibility.md) | `MetaSonic.Core` facade |
| SAPF comparison               | [2026-05-25-c-sapf-metasonic-design-comparison.md](2026-05-25-c-sapf-metasonic-design-comparison.md) | authoring semantics above bridge |
| Public architecture summary   | [README.md](../README.md)                              | Authoring layer, session preparation APIs            |
| Primitive source DSL          | [Source.hs](../src/MetaSonic/Bridge/Source.hs)         | `Connection`, `SynthM`, `runSynth`, `UGen`           |
| Transparent authoring layer   | [Authoring.hs](../src/MetaSonic/Authoring.hs)          | `Mono`, `Stereo`, `Channels`, `AuthoredEnsemble`     |
| Template compiler             | [Templates.hs](../src/MetaSonic/Bridge/Templates.hs)   | `compileTemplateGraph`, `TemplateGraph`              |
| Pattern layer                 | [Pattern.hs](../src/MetaSonic/Pattern.hs)              | `Pattern`, `PatternEvent`, `expandPattern`           |
| Session command bridge        | [Command.hs](../src/MetaSonic/Session/Command.hs)      | `SessionCommand`, `fromPatternEvent`                 |
| Pattern producer              | [PatternProducer.hs](../src/MetaSonic/Session/PatternProducer.hs) | `enqueuePatternBlock`                         |
| Producer fan-in               | [FanIn.hs](../src/MetaSonic/Session/FanIn.hs)          | `SessionFanIn`, producer ingress                     |
| Live session shell            | [ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs) | `LiveSessionCommand`                      |
| Runtime adapter               | [RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs) | preserving/rebuild hot-swap boundary          |


## What Survives From The Draft

The old draft is still useful as a product note. It correctly points at
four desirable properties:

- users should write normal Haskell, not a separate parser language;
- the most common musical expressions should be compact;
- patch files should eventually support a fast edit/test/listen loop;
- type and validation information should help the author before
  realtime execution.

Those goals still fit the project. The implementation route changes.

The useful replacement thesis is:

```text
Make authoring syntax nicer by elaborating to the compiler surfaces
that already exist. Do not replace those surfaces.
```


## What Must Not Carry Forward

The stale parts of the draft should not be used as current guidance:

- no new `NodeExpr` IR as "what the bridge consumes";
- no separate `Sig` compiler that bypasses `SynthM` and `SynthGraph`;
- no broad `Num Sig` promise that arbitrary audio-rate arithmetic
  works like scalar Haskell arithmetic;
- no `Floating Sig` where `sin` ambiguously means "math sine" or
  "oscillator";
- no `mdo` feedback story for realtime cycles;
- no `hint` integration described as a small drop-in runtime;
- no `swapGraph compiled` path that bypasses `SessionCommand`,
  `RTGraphAdapter`, preserving-swap policy, and manifest reload
  semantics;
- no C++ JIT mental model for tinysynth.

Those ideas either conflict with the current architecture or hide
important realtime ownership questions.


## Current Syntax Layers

### Primitive Source Layer

`MetaSonic.Bridge.Source` is the current primitive graph-authoring
layer:

```haskell
runSynth :: SynthM a -> SynthGraph

data Connection
  = Audio NodeID PortIndex
  | Param Double
```

Primitive builders allocate named `UGen` nodes in `SynthM`:

```haskell
sinOsc :: Connection -> Connection -> SynthM Connection
sawOsc :: Connection -> Connection -> SynthM Connection
lpf    :: Connection -> Connection -> Connection -> SynthM Connection
gain   :: Connection -> Connection -> SynthM Connection
add    :: Connection -> Connection -> SynthM Connection
out    :: Int -> Connection -> SynthM ()
```

Numeric literals work because `Connection` has `Num` and `Fractional`
instances for literal `Param` values. Runtime signal arithmetic does
not use those instances. It must allocate graph nodes through `add`,
`gain`, or another explicit primitive.

That policy is good. It keeps constant folding separate from realtime
DSP and makes node allocation visible.

Correct primitive style today:

```haskell
subtractive :: SynthGraph
subtractive = runSynth $ do
  osc <- sawOsc 110.0 0.0
  flt <- lpf osc 800.0 0.7
  amp <- gain flt 0.4
  out 0 amp
```

### Authoring Layer

`MetaSonic.Authoring` is the current bridge-local authoring facade. It
adds typed authoring shapes:

```haskell
newtype Mono = Mono Connection
data Stereo = Stereo Connection Connection
newtype Channels = Channels [Connection]
```

These shapes are not runtime buffers. They are authoring-time wrappers
around mono `Connection`s. The lowered graph still consists of normal
primitive nodes.

Correct authoring style today:

```haskell
wideSubtractive :: SynthGraph
wideSubtractive = runSynth $ do
  osc <- sawOsc 110.0 0.0
  flt <- lpf osc 800.0 0.7
  st  <- Auth.pan2 (Auth.mono flt) (-0.25)
  wet <- Auth.gainS st 0.4
  Auth.outStereo 0 wet
```

The important property is not the exact spelling. The important
property is transparent lowering: each helper emits the same primitive
`UGen` nodes a hand-written graph would emit.

### Core Facade

`MetaSonic.Core` is a likely future public surface, not a replacement
for `MetaSonic.Bridge.Source` or `MetaSonic.Authoring`.

The first Core slice should be lexical and shallow. Two stances are
possible; the slice should pick one and stay consistent:

```haskell
-- Stance A: exact-arity aliases. Names change, arity does not.
saw        = sawOsc          -- :: Connection -> Connection -> SynthM Connection
pulse      = pulseOsc        -- :: Connection -> Connection -> Connection -> SynthM Connection
tri        = triOsc          -- :: Connection -> Connection -> SynthM Connection
whiteNoise = noiseGen        -- :: SynthM Connection
noise      = whiteNoise

-- Stance B: ergonomic single-arg helpers. Phase / extra args defaulted.
saw   f = sawOsc f 0.0
pulse f = pulseOsc f 0.0 0.5
tri   f = triOsc f 0.0
```

The Core naming note already makes the key boundary explicit:

```text
Core names may make graph authoring more comfortable.
Core names must not change graph meaning.
```

Stance A is the safer first slice: arity is preserved and the emitted
graph is byte-identical to the existing spelling. Stance B *does*
change graph meaning in one direction — it picks a default for a knob
the user could otherwise supply — but the default is explicit and
testable. It can be added later under names that advertise defaulting.

Do not mix the two in the first slice (e.g. exact-arity `saw` next to
defaulted `pulse`). That creates an inconsistent surface that a future
user can't learn once.

For slice 1, source aliases should return `Connection`, matching the
primitive source layer. If a later layer wants `Mono`-returning helpers,
that should be deliberately named or live in a separate module so the
first public Core API does not create a future type break.

### Pattern And Session Layer

Temporal and live behavior does not belong in a graph-expression IR.
It already has a project-specific home:

```text
Pattern -> PatternEvent -> SessionCommand -> producer fan-in -> owner/adapter
```

`Pattern` is a pure deterministic producer of timed symbolic events.
`SessionCommand` is the normalized command vocabulary shared by
patterns, OSC, MIDI, UI, and manifest reloads. The fan-in and owner
layers serialize, validate, and apply those requests.

This replaces the old draft's `pendingPatch` / `swapGraph` sketch. A
future authoring shell should submit prepared `SessionCommand`s. It
should not mutate the runtime directly.

### Live Session Shell

The current live shell syntax is operator syntax, not a Haskell patch
language:

```text
demo:KEY
demo KEY
demos
controls
values
set TAG VALUE
status
help
quit
```

That is useful and should stay small. It is for supervised reloads,
control inspection, and control writes against already prepared
manifest/demo material. It is not the place to evaluate arbitrary
Haskell snippets.


## Replacing `Sig` And Signal Arithmetic

The old draft's largest attraction is this shape:

```haskell
fm = sine (440 + 200 * sine 3)
```

That is a good authoring dream, but the naive `Num Sig` route is not a
good bridge design today.

Reasons:

- `SynthM` allocation is effectful state. A pure `Sig -> Sig`
  expression hides where nodes are created.
- sharing matters. Reusing one Haskell value should not accidentally
  duplicate a whole subgraph or change migration keys.
- arithmetic over `Connection` cannot allocate `KAdd` or `KGain`
  nodes without being inside `SynthM`;
- `Floating` names are semantically overloaded. `sin` as a math
  function is not the same thing as `sinOsc`;
- broad overloading would make error messages and lowering tests
  harder to understand.

Near-term rule:

```text
Keep runtime audio math explicit: use add/gain or named authoring
helpers. Keep numeric literals convenient only for Param constants.
```

A future signal-expression experiment is allowed, but it should be a
separate `MetaSonic.Core.Experimental.Signal` style slice with a clear
sharing model. It must prove:

- each expression lowers to a predictable primitive `SynthGraph`;
- repeated references have documented sharing or duplication behavior;
- migration keys and node order are deterministic;
- error messages explain unsupported arithmetic;
- no runtime or compiler layer has to understand `Sig` specially.


## Pipe And Chain Syntax

The old draft's `|>` instinct is worth keeping, but the current
primitive builders are monadic. A plain function pipeline does not fit
every builder without hiding allocation.

Good current style:

```haskell
voice :: SynthGraph
voice = runSynth $ do
  src <- sawOsc 110.0 0.0
  flt <- lpf src 1200.0 0.7
  amp <- gain flt 0.3
  out 0 amp
```

Useful future Core helpers could improve this without new semantics:

```haskell
chainM
  :: a
  -> [a -> SynthM a]
  -> SynthM a

withGain :: Connection -> Connection -> SynthM Connection
withLpf  :: Connection -> Connection -> Connection -> SynthM Connection
```

Example target style:

```haskell
voice = runSynth $ do
  src <- saw 110
  sig <- chainM src
    [ \x -> lpf x 1200 0.7
    , \x -> gain x 0.3
    ]
  out 0 sig
```

The `chainM` shape is deliberately uniform (`a -> SynthM a`); each step
that needs extra parameters absorbs them through a lambda, as above.
That keeps the helper one-typeclass-free at the cost of a small visual
overhead. Resist the temptation to invent a `Chainable` class that
matches multiple arities — it pulls authoring back toward exactly the
type machinery this note is trying to defer.

This is intentionally modest. It keeps node allocation in `SynthM` and
does not invent an expression IR.


## Patch Forms Instead Of Open Syntax

The best way to make syntax useful now is not a parser or `hint`. It is
small Haskell records/functions that describe patch families.

Conservative shape:

```haskell
data SimpleVoice = SimpleVoice
  { svFreq   :: Connection
  , svCutoff :: Connection
  , svQ      :: Connection
  , svLevel  :: Connection
  }

simpleVoice :: SimpleVoice -> SynthM Auth.Mono
simpleVoice p = do
  src <- sawOsc (svFreq p) 0.0
  flt <- lpf src (svCutoff p) (svQ p)
  Auth.gainM (Auth.mono flt) (svLevel p)
```

Variants are ordinary Haskell:

```haskell
bright :: SimpleVoice -> SimpleVoice
bright p = p { svCutoff = 5000.0 }
```

This lines up with the SAPF comparison note's "patch forms above
templates" direction. It gives users named parameters and variants
without changing `SynthGraph` or `TemplateGraph`.


## File-Based Workflow

The old draft says "watch a `.hs` file and hot-swap on save." That is
still a good user workflow, but it is not a 100-line `hint` wrapper.

Correct current architecture for a future file workflow:

```text
patch file changes
  -> compile/evaluate authoring code outside the audio thread
  -> produce SynthGraph or AuthoredEnsemble
  -> compile to RuntimeGraph or TemplateGraph
  -> validate manifest/control/session policy
  -> submit CmdHotSwap or CmdHotSwapPreservingOnly
  -> RTGraphAdapter installs or rejects according to policy
```

There are two viable implementation tracks:

1. **Compiled helper executable.** The user edits normal Haskell,
   rebuilds or reruns a helper, and the helper emits a manifest/demo
   selection or directly prepares a `TemplateGraph`.
2. **Interpreter experiment.** A separate `hint`/GHCi-backed prototype
   evaluates Haskell authoring code, but only to produce finite
   prepared artifacts. It still submits through the session layer.

Track 1 is lower risk. Track 2 is a research slice because it raises
dependency, sandboxing, module-import, latency, type-error rendering,
state retention, and safety questions. It also runs interpreted code
inside the same process as the audio engine, which links the
interpreter's RTS behavior (allocation, GC pauses, thread state) to the
realtime path's liveness in ways that are not obvious from looking at
the API surface. A subprocess split — interpreter in one process,
audio engine in another, session commands across an IPC boundary —
isolates that risk and should be the default if track 2 is pursued.

Either track must keep compile failures off the realtime path.


## Validation And Error Surface

The old draft's `GraphM` validation idea is pointing at a real
weakness: authoring errors should become structured diagnostics where
possible.

Current state:

- primitive graph validation belongs to the bridge compiler;
- `compileTemplateGraph` owns template ordering and resource-cycle
  checks;
- `Pattern` contracts are checked by expansion/driver tests;
- session admission reports producer-facing rejections through
  `SessionEvent` / `SessionIssue`;
- some authoring helpers still use direct failures for authoring-time
  misuse, such as mismatched channel counts.

Future authoring work should improve diagnostics at the highest layer
that has enough context:

- channel-count mismatch should eventually be a structured authoring
  diagnostic;
- unknown named bus/control should be reported before compile/load;
- manifest/control target mismatch should stay in manifest reload
  planning;
- runtime install rejection should stay in the session/adapter result
  types.

Do not add a second validator that duplicates bridge semantics.

A good diagnostic slice should move one existing direct failure into a
structured result and prove that downstream bridge/session errors remain
unchanged. If the change requires widening `SynthM` or teaching the
bridge about authoring metadata, it is too broad for the first pass.


## Feedback And Delay

The old `RecursiveDo` feedback example should be removed from current
guidance. Feedback in MetaSonic is explicit:

- `delayL maxDelay signal time` is a per-node delay line with a
  compile-time maximum delay;
- `busInDelayed bus` reads the previous block's bus snapshot and is
  the source-level feedback primitive for shared-bus loops.

Correct feedback mental model:

```text
same-block live cycles are rejected or unschedulable;
delayed feedback is represented by explicit delay/bus primitives;
the compiler/runtime can see the temporal boundary.
```

This keeps graph scheduling and resource ordering honest.


## Rate And Type Direction

The old draft's phantom `AudioRate` / `ControlRate` sketch is useful
as a research prompt, not as current bridge direction.

Current bridge state already has:

- `Rate` metadata;
- `PortConsumptionRate`;
- `kindSpec` intrinsic floors;
- `propagateRates`;
- block-latched and sample-rate behavior documented per node/port.

The near-term gap is not a type-indexed rewrite. The practical gap is
the sample-accurate connected-control story and continued per-port
execution evidence.

Future Core-level typed APIs may be useful, but they should start as
thin authoring wrappers over the current bridge. They should not
replace `SynthGraph` or `Connection` until there is evidence that users
benefit enough to justify the complexity.


## Non-Goals

This note does not propose:

- adding `NodeExpr`;
- adding a separate `Sig` compiler path;
- changing `Connection` into an audio-expression AST;
- adding numeric class instances on `Connection` / `Sig` that allocate
  realtime arithmetic nodes (covers `Num`, `Floating`, and any future
  overloaded-math route);
- importing `hint` into the main runtime path;
- watching and evaluating files on the audio thread;
- bypassing `SessionCommand` or `RTGraphAdapter` for live swaps;
- changing `NodeKind` tags or C++ runtime ABI;
- embedding Core/Authoring metadata into `SynthGraph` or
  `TemplateGraph`;
- making the live session shell a Haskell REPL.


## Practical Future Slices

1. **Core facade slice.** Add `MetaSonic.Core` as a shallow public
   module with exact-arity source aliases and selected authoring
   re-exports. Test that each alias lowers to the same primitive graph
   as the existing spelling.

2. **Pipeline helper slice.** Add small monadic chain helpers if real
   patches show repeated boilerplate. Test construction order and
   emitted primitive shapes.

3. **Patch-form slice.** Add one record/function patch-family example
   around existing demos or corpus rows. This is the first musical
   authoring slice from the SAPF comparison note. Test defaults,
   variants, named controls, generated reports, and manifest output.

4. **Authoring diagnostics slice.** Replace one narrow authoring-time
   direct failure with a structured diagnostic path only if the caller
   surface can carry it without widening `SynthM` everywhere.

5. **File workflow prototype.** Start with a compiled helper or script
   that rebuilds/prepares a known patch artifact and submits through
   the existing live reload/session path. Record compile failure and
   swap rejection behavior before considering an interpreter.

6. **Experimental signal-expression slice.** Only after the above,
   prototype a separate `Sig`-like authoring wrapper if there is still
   pressure for infix audio math. The test bar must pin sharing, node
   order, migration keys, and lowering transparency.


## Reference Thesis

MetaSonic syntax should become pleasant by making the current system
easier to drive, not by adding a parallel system.

The durable rule:

```text
Authoring syntax may be friendly.
Lowering must remain explicit.
Compiled artifacts must remain finite.
Runtime mutation must stay behind the session/runtime owners.
```

That rule preserves the useful instinct from the old draft while
keeping the project aligned with the compiler, authoring, session, and
runtime contracts that now exist.
