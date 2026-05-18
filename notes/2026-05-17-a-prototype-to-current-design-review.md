# Prototype To Current Design Review

Status: design review after comparing the public prototype repository with the
current local checkout.

This note answers two questions:

1. How is the current repository different from the earlier prototype?
2. Did development move in the right direction, or did it drift away from the
   original design principles?

## Compared Snapshots

Prototype snapshot:

- Source: <https://github.com/smoge/metasonic-bridge>
- Local shallow clone used for comparison: `/tmp/metasonic-bridge-prototype`
- Commit observed: `f6df827`

Current checkout snapshot:

- Repository: `/home/smoge/metasonic/metasonic-bridge`
- Branch: `main`
- Commit observed: `39f1def`
- The working tree also had uncommitted local edits around the preserving demo
  pair and manifest reload tests. This review is architectural, so those edits
  are treated as part of the active local direction but not as committed
  history.

## Short Answer

The code moved in the right direction.

It drifted heavily in scope, but mostly not in principle. The prototype was a
compact compiler/runtime proof. The current checkout is now a compiler/runtime
plus session/control substrate: templates, authoring metadata, OSC/MIDI/UI
producer adapters, manifest reload planning, preserving hot-swap, fusion
measurement, operator smokes, and a large regression suite.

That is a large expansion, but the core rule still holds:

```text
Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> DSP Engine
```

The current code still resolves structure before the C++ audio loop sees it.
The symbolic control names, manifests, voice keys, OSC paths, MIDI mappings,
and authoring metadata live on the Haskell/control side. They are projected
into concrete runtime node indices, control slots, template ids, instance
slots, and prewarmed resources before they touch realtime execution.

## Prototype Shape

The public prototype was intentionally small:

- 8 Haskell library modules.
- 1 app module.
- 1 placeholder Haskell test file.
- 2 tinysynth C++ files.
- About 4.4k lines across `src/`, `app/`, `test/`, and `tinysynth/`.

Its `package.yaml` exposed the direct bridge pipeline:

- `MetaSonic.Types`
- `MetaSonic.Bridge.Source`
- `MetaSonic.Bridge.Validate`
- `MetaSonic.Bridge.IR`
- `MetaSonic.Bridge.Compile`
- `MetaSonic.Bridge.FFI`
- `MetaSonic.Visualize.Trace`
- `MetaSonic.Visualize.TUI`

The README described the design in its purest form:

- graph construction is a compiler problem;
- DSP execution is a runtime problem;
- no symbolic lookups in the audio thread;
- no runtime graph solving;
- static precompiled graphs;
- minimal node set;
- TUI inspection and direct audio playback.

The app was also the demo registry. `app/Main.hs` defined small graphs such as
`simple`, `chain`, `fanout`, `saw`, `noise`, `noise-lpf`, `saw-lpf`, and
`detune`, then played or inspected them.

The test suite was not yet a suite:

```haskell
main :: IO ()
main = putStrLn "Test suite not yet implemented"
```

## Current Shape

The current checkout is much broader:

- 58 Haskell library modules.
- 32 app modules.
- 31 Haskell test modules.
- 15 tinysynth C++ files.
- About 85.6k lines across `src/`, `app/`, `test/`, and `tinysynth/`.

The rough line split is:

| Area                          |  Lines | Share |
|-------------------------------|-------:|------:|
| `src/` Haskell library        | 22,738 | 26.6% |
| `tinysynth/` C++ runtime      | 15,137 | 17.7% |
| `app/` CLI and operator tools | 15,974 | 18.7% |
| `test/` Haskell tests         | 31,739 | 37.1% |
| Total                         | 85,588 |  100% |

This is no longer a small proof of concept. It is a research workbench and
runtime-control substrate.

The dependency footprint also shows the boundary shift. The prototype library
only needed the small compiler/TUI set: `containers`, `mtl`, `deepseq`, and
the Brick/Vty inspector stack. The current library adds `bytestring`,
`network`, `text`, `aeson`, and `aeson-pretty`. Those are useful for OSC
packets, listener sockets, text identities, and authoring manifests, but they
are also concrete evidence that bridge-local code now carries session/control
policy that was outside the prototype's original compiler-only footprint.

## Major Differences

### 1. The compiler pipeline expanded, but was not replaced

The original compiler path still exists, but `Compile.hs` is no longer one
monolithic home for all lowering behavior. It has been split into explicit
submodules for:

- runtime graph types;
- dependency and scheduling analysis;
- region formation;
- region-kernel selection;
- edge-rate and latency metadata;
- fusion support;
- generated-fusion program scaffolding.

This is the right kind of expansion. It makes the compiler more explicit
instead of burying new behavior in the app or runtime.

The main risk is that generated-fusion scaffolding can remain permanently
experimental. It should either become a real fourth execution path or stay
clearly labelled as measurement/design scaffolding.

### 2. The runtime moved from one loaded graph to live-owned resources

The prototype loaded a compiled graph and played it.

The current runtime owns:

- template graphs;
- prewarmed template instances;
- realtime reserve/activate/release/remove operations;
- realtime control writes;
- bus and buffer pools;
- static plugin dispatch;
- MIDI source adapters;
- preserving hot-swap support;
- migration counters and swap generation checks.

This is a major scope increase, but it follows the original "decide before the
audio thread" principle. Runtime mutability is not arbitrary graph solving on
the audio thread. It is a narrow command surface over precompiled templates,
prewarmed resources, concrete slots, and explicit swap protocols.

### 3. Authoring moved into the bridge, temporarily

The prototype README positioned `metasonic-core` as the future user-facing DSL
above the bridge.

The current checkout carries `MetaSonic.Authoring` inside the bridge. This is
the clearest intentional boundary bend.

The important saving detail is that `MetaSonic.Authoring` is transparent. Its
module header says it elaborates to ordinary `SynthGraph` / `TemplateGraph`
values and is not a second compiler. That keeps the architectural contract
intact.

This should still be treated as temporary. When the authoring surface settles,
the durable direction is to move the user-facing API upward into a core layer
or keep it explicitly named as bridge-local authoring support.

### 4. Session/control code became the largest conceptual addition

The prototype did not have a session model. The current checkout has a
`MetaSonic.Session.*` layer for:

- normalizing producer intents into `SessionCommand`;
- keeping session state and checked commits;
- resolving voice/control targets after graph changes;
- owning a real `RTGraph` through `SessionOwner` and `RTGraphAdapter`;
- queueing producer commands;
- composing Pattern, OSC, MIDI, and UI producers;
- serializing producer traffic through fan-in;
- handling preserving hot-swap for eligible graph changes.

This is mostly good direction. It gives Pattern, OSC, MIDI, UI, and manifest
reload one shared command vocabulary instead of letting every producer grow a
private runtime path.

The risk is that the session layer can become a framework before it becomes a
clear instrument. The code has avoided the worst version of that by keeping
many pieces deterministic and testable, but the product shape still needs
consolidation.

The natural creep point is `MetaSonic.Session.RTGraphAdapter`. At 1,121 lines,
it is no longer just a thin bridge over `RTGraph`; it is where runtime
installation, preserving hot-swap eligibility, migration checks, prewarm
policy, and resolve-state rebuilding meet. That may be the right ownership for
now, but it is the first file to watch when runtime policy starts feeling less
like an adapter and more like a second owner.

### 5. Manifest reload is metadata validation, not JSON graph execution

The manifest system could have drifted badly if JSON became a second graph
language.

The current design avoids that. `MetaSonic.Session.ManifestReload` validates a
decoded authoring manifest against an app-owned catalog and then produces a
static plan. It does not reconstruct arbitrary graphs from JSON, allocate an
`RTGraph`, step a session owner, or choose a live hot-swap protocol by itself.

That is the right direction. It keeps manifests as descriptions of authored
surfaces and resource policy, not as an interpreter bypassing the compiler.

### 6. The app became an operator laboratory

The prototype app had three modes:

- direct audio;
- inspect then run;
- inspect only.

The current app has many modes:

- fusion survey;
- worker benchmark;
- swap benchmark;
- corpus survey;
- fusion cost lab;
- snapshot check;
- manifest export;
- manifest reload planning;
- session construction smoke;
- stopped-audio reload smoke;
- host strategy smoke;
- OSC listener;
- MIDI device listing;
- session MIDI smoke;
- manifest MIDI reload smoke;
- live manifest reload demo.

This is useful scaffolding, but it is also where drift pressure is strongest.
The app now reads like a lab bench. That is acceptable for this phase, but not
as the long-term operator surface.

The next design cleanup should not remove these tools blindly. It should
graduate proven flows into one or two coherent operator commands, then leave
the rest as explicitly diagnostic.

### 7. Tests changed the character of the project

The prototype had no real test suite. The current checkout has more than
31k lines of Haskell tests, plus C++ runtime tests outside this line count.

This is not ornamental. Most of the new behavior is exactly the kind that
needs tests:

- Haskell/C++ tag and arity drift;
- dense lowering;
- scheduler invariants;
- bus and buffer effects;
- FFI behavior;
- OSC parsing and dispatch;
- MIDI producer behavior;
- fan-in queue semantics;
- preserving hot-swap;
- manifest reload planning and app-level projections.

This much test code is a sign of scaffolding, but it is also the reason the
larger scope has not obviously violated the original realtime constraints.

There is a qualification: the tests prove rigor, but their hygiene has not kept
pace with the compiler code. The compiler split into focused modules; several
test files are now megafiles:

- `test/MetaSonic/Spec/Core.hs`: 5,181 lines.
- `test/MetaSonic/Spec/Session.hs`: 5,352 lines (split into
  twenty-two `MetaSonic.Spec.Session.*` submodules plus
  `MetaSonic.Spec.SessionShared`; see
  `notes/2026-05-18-a-session-megafile-split-recap.md`).
- `test/MetaSonic/Spec/FFI.hs`: 3,914 lines (split into ten
  `MetaSonic.Spec.FFI.*` submodules; see
  `notes/2026-05-17-b-ffi-megafile-split-recap.md`).
- `test/MetaSonic/Spec/Feature.hs`: 2,836 lines (split into ten
  `MetaSonic.Spec.Feature.*` submodules; see
  `notes/2026-05-18-b-feature-megafile-split-recap.md`).

That is not a correctness failure, but it is a maintainability signal. The
test suite is no longer just evidence of rigor; it is also carrying unrefactored
project history. The compiler got structural hygiene. The tests should get the
same treatment.

## How Much Is Scaffolding?

By line count, a blunt answer is:

- About 44% is core library/runtime (`src/` + `tinysynth/`).
- About 56% is app tooling plus tests (`app/` + `test/`).

That does not mean 56% is disposable. In this project, a lot of scaffolding is
evidence machinery:

- deterministic tests for realtime-adjacent semantics;
- CLI smokes for hardware or audio paths CI cannot prove;
- survey and cost-lab tools to decide whether optimizations are real;
- manifest/reload diagnostics to keep policy separate from runtime effects.

The concern is not the amount of scaffolding. The concern is whether each
scaffold has an exit condition.

A good scaffold has one of these outcomes:

1. It becomes a user-facing/operator flow.
2. It remains a small regression/diagnostic tool.
3. It is removed after the real path supersedes it.

A bad scaffold just accumulates flags and vocabulary forever.

## Drift From Original Principles

### Principle: no symbolic lookups in the audio thread

Mostly held.

Symbolic names now exist everywhere in the control plane: voice keys, template
names, migration keys, OSC paths, manifest control rows, MIDI mappings. But the
runtime still resolves them before realtime processing. The audio side sees
concrete instance slots, node indices, control slots, bus ids, buffer ids, and
template ids.

This is scope growth, not principle drift.

### Principle: graph construction is a compiler problem

Held, with a broader meaning.

The current system does modify running sessions, but the modifications are
still compiled/planned outside the audio loop. Preserving hot-swap is not "edit
the graph in the callback"; it is prepare, publish, wait for generation,
collect/verify, then commit.

The phrase "static precompiled graphs" is now too small. A better current
phrase is:

```text
Precompiled templates, explicit runtime commands, and checked graph swaps.
```

### Principle: bridge and runtime are separate worlds

Mostly held.

Haskell still builds and analyzes. C++ still executes DSP. The bridge carries
more policy now, especially session policy, OSC/MIDI translation, and manifest
planning. That is reasonable because those are control-plane concerns.

The mild drift is `MetaSonic.Authoring` living in the bridge. It is acceptable
while the API is still being discovered, but it should not be mistaken for the
final package boundary.

### Principle: the runtime is deterministic and strict

Improved, but more complex.

The runtime now has more moving parts: queues, voice lifecycle, buffers,
plugins, MIDI, hot-swap, and migration. Complexity increased. But the code also
adds explicit queues, prewarming, migration checks, generation waits, and
deterministic tests.

This is the right trade for live control, as long as the project keeps
rejecting hidden allocation or symbolic dispatch in the audio path.

### Principle: Haskell/C++ agreement must be explicit

Improved.

The prototype already needed Haskell/C++ kind agreement. The current checkout
has a larger ABI and therefore more drift risk, but it also has tests and
metadata checks for kind tags, arities, node support, plugin registry behavior,
and FFI smoke behavior.

The risk grew, but the guard rails grew with it.

## High-Level Judgment

The current code is not a betrayal of the prototype. It is the prototype grown
into the missing middle layer.

The original version proved:

```text
Can we compile a graph and run it deterministically?
```

The current version is answering:

```text
Can a compiled realtime graph be controlled, reloaded, inspected, tested, and
operated without giving up deterministic execution?
```

That is the right next question.

The project has not drifted into a SuperCollider-style dynamic server. It has
instead built a stricter control plane around precompiled runtime objects.

## Main Risks Now

1. App-mode sprawl.

   The CLI has become a research console. That is useful, but the project needs
   one or two blessed operator paths so users do not need to understand every
   intermediate smoke command.

2. Authoring package boundary.

   `MetaSonic.Authoring` is useful and intentionally transparent. It should
   remain transparent until it moves upward into the future core/user-facing
   layer.

3. Manifest semantics.

   Manifests should stay metadata and policy descriptions. They should not
   become a second patch language unless that is designed explicitly.

4. Scaffolding without retirement.

   Each benchmark, smoke, and diagnostic mode should have a durable purpose or
   a retirement condition.

5. Manual validation gaps.

   MIDI hardware, OSC sockets, and audible reload paths need manual/operator
   runbooks because CI cannot fully prove them. That split is healthy, but the
   project should keep deterministic tests as the default gate.

6. Test megafiles.

   The largest test files are now harder to navigate than the implementation
   areas they protect. Splitting by subsystem and behavior would make future
   regressions easier to localize without weakening coverage.

7. Library dependency creep.

   `aeson`, `aeson-pretty`, `network`, `text`, and `bytestring` are the most
   concrete dependency-level signs that bridge-local code is carrying control
   and session policy. That may be valid for this phase, but it gives a clear
   cleanup target when package boundaries are revisited.

8. `RTGraphAdapter` policy accumulation.

   See the session/control section above; if this file keeps growing, split
   policy decisions from raw runtime adapter mechanics.

## Recommendations

1. Consolidate the operator story.

   Keep the current diagnostic commands, but identify the main intended flows:
   author manifest, start session, control from OSC/MIDI, reload preserving or
   stopped-audio, verify visible outcome.

2. Keep authoring transparent.

   Do not add hidden runtime semantics to `MetaSonic.Authoring`. Every helper
   should continue to lower to ordinary primitive graph shapes, and tests should
   keep pinning that.

3. Attach exit criteria to scaffolding.

   For each app smoke or lab mode, decide whether it is:

   - a permanent diagnostic;
   - a temporary proof tool;
   - a future user/operator command.

4. Avoid another producer surface until OSC/MIDI reload is operator-clean.

   The current control side already has Pattern, OSC, MIDI, UI, manifest, and
   fan-in. The next gain is not another producer. It is making the existing
   path easier to run and trust.

5. Keep the Haskell/C++ contract aggressively tested.

   Every new runtime kind, plugin shape, buffer behavior, or preserving-swap
   rule should continue to land with Haskell tests plus C++ or FFI coverage
   where Haskell cannot observe the behavior directly.

6. Split the test megafiles.

   `Session.hs`, `FFI.hs`, and `Feature.hs` have already been split
   this way; `Core.hs` remains as the outstanding hygiene target.
   Split by ownership boundary and behavior class while preserving
   the same Tasty entrypoint.

7. Use dependencies as package-boundary evidence.

   When deciding what should leave the bridge later, start from the deps that
   were absent in the prototype: `network` and `bytestring` point to OSC/wire
   IO, `aeson` and `aeson-pretty` point to manifest/reporting, and `text`
   mostly supports producer/session identity plumbing.

## Final Assessment

The project is no longer just a prototype graph compiler. It is now a
compiler-first realtime audio substrate with a serious control/session layer.

That is the correct direction for the original design. The code did not drift
from the central principle that the audio thread should execute already-decided
structure. It drifted from minimalism.

The next phase should be consolidation, not rollback:

- keep the compiler/runtime separation;
- keep session commands as the shared producer vocabulary;
- keep manifests descriptive;
- reduce operator friction;
- retire or bless scaffolding as evidence accumulates.

If that consolidation happens, the current expansion will read as necessary
infrastructure. If it does not, the project risks becoming a pile of excellent
experiments without one clear instrument-shaped path through them.
