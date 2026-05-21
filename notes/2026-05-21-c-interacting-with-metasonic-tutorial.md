# Interacting with MetaSonic: CLI and Haskell tutorial (2026-05-21)

Status: tutorial / reference. Snapshot of the interaction surface as
of 2026-05-21. The surface moves; treat this as a starting map, not
a contract. When in doubt, the authoritative sources are:

- `app/Main.hs` for the CLI dispatch (search for `go opts (...)`),
- the `justfile` for the recipe vocabulary,
- `src/MetaSonic/Bridge/Source.hs` for the DSL,
- the `Note [Pipeline reading order]` at the top of
  [src/MetaSonic/Types.hs](../src/MetaSonic/Types.hs) for the
  pipeline stages.

This note is organized by *what you want to do*, not by what API
exists. Each subsection gives one minimum working invocation plus a
pointer to where to look for the full surface. It is not exhaustive
by design — exhaustive enumeration goes stale; task-oriented entry
points stay useful.

## Scope

In scope: every interaction path you can reach with what's currently
in this repo's tracked tree as of 2026-05-21.

Out of scope:

- Internal supervisor / session-layer APIs that are not user-facing
  (consult the relevant `notes/` design notes if you need to extend
  them).
- The pattern producer's `Pattern` DSL beyond what's needed for the
  corpus survey (still gated behind real-producer evidence per the
  Phase 6.A closeouts).
- The C++ runtime's internal scheduler / worker pool tuning knobs
  (test-gated; see ROADMAP §4.E).

If you find a path that is not covered here and that you used more
than once, it belongs in this note — append it.

---

# Part A. Command-line surfaces

The Haskell-built binary is `metasonic-bridge`. The `justfile` wraps
the common invocations; `stack exec -- metasonic-bridge <args>` is
the equivalent direct form. The C++ side has its own standalone
build under `build-cpp/` driven by CMake; that's covered separately
in §A.10.

## A.1 Run a built-in demo synth (audio)

The fastest way to hear something.

```sh
just metasonic                 # run all demos in sequence
just metasonic chain           # run the chain demo only
just metasonic-help            # list demo names
```

Demo synth graphs are defined in
[app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs); CLI
dispatch lives in [app/Main.hs](../app/Main.hs). The authoritative
list of keys is `demoTable` in that file. As of this writing:
`simple`, `chain`, `fanout`, `saw`, `noise`, `noise-lpf`,
`saw-lpf`, `detune`, `stereo-saw`, `stereo-fx`, `ringmod`, `fm`,
`env-pluck`, `im`, `named-control`, `send-return`,
`preserve-cutoff-dark`, `preserve-cutoff-bright`,
`reject-preserving-smooth-dark`, `reject-preserving-smooth-bright`,
`midi-poly`. Run `just metasonic-help` to print the live list with
descriptions.

`midi-poly` and `midi-poly-device` need a connected MIDI controller.
`--midi-device` takes a non-negative integer device index, not a
device name; `just midi-list` is the discovery step:

```sh
just midi-list                 # enumerate MIDI input devices with indices
just midi-poly                 # default device
just midi-poly-device 2        # device index 2
```

## A.2 Inspect a graph (TUI)

A brick-based pipeline inspector that walks the
SynthGraph → GraphIR → RuntimeGraph stages with per-stage trace.

```sh
just metasonic-inspect chain        # inspector, then play audio
just metasonic-inspect-only chain   # inspector only, no audio
```

The inspector is in [src/MetaSonic/Visualize/TUI.hs](../src/MetaSonic/Visualize/TUI.hs);
per-stage trace data in [src/MetaSonic/Visualize/Trace.hs](../src/MetaSonic/Visualize/Trace.hs).

## A.3 Surveys and benchmarks

Read-only diagnostics that walk the demo / pattern corpus and report
on fusion coverage, rate distribution, hot-swap, and worker-pool
behavior. None of these enable runtime parallelism — they are
descriptive only.

```sh
stack exec -- metasonic-bridge --fusion-survey
stack exec -- metasonic-bridge --corpus-survey
stack exec -- metasonic-bridge --worker-bench
stack exec -- metasonic-bridge --swap-bench
stack exec -- metasonic-bridge --snapshot-check
stack exec -- metasonic-bridge --fusion-cost-lab
```

- `--fusion-survey` reports per-demo kernel coverage and the ranked
  missed-shape table (the §4.B.x kernel-add gate input).
- `--corpus-survey` runs the pattern-producer corpus through the
  same survey machinery (Phase 6.A.3).
- `--worker-bench` measures the Haskell-loaded worker-pool dispatch
  decision (§4.E.C1d). Default-off; the bench is informational.
- `--swap-bench` measures hot-swap prepare / publish / install /
  collect cost across a fixed corpus.
- `--snapshot-check` is a determinism / corpus-drift gate.
- `--fusion-cost-lab` is the Phase 7.A fusion cost lab: it
  generates a fixed bank of shapes and reports cost-model output
  (opt-in, not default). Later phases gained generated-runtime
  variants, but the command itself is Phase 7.A.

`--summary` is specific to `--fusion-cost-lab`: it sets
`optFCLSummary` so the cost-lab prints a single-line headline
instead of its full per-shape report. It does not apply to the
other surveys.

## A.4 Plugin host

```sh
just plugin-list
stack exec -- metasonic-bridge --plugin-list
```

Lists statically-registered `KStaticPlugin` entries (Phase 6.E
slice 2). Slice 3's metadata follow-up is parked.

## A.5 OSC ad-hoc control

Listen on a port (prints decoded packets to stdout):

```sh
just osc-listen 7000
```

Send a single packet (uses the in-tree Python helper, no system
package needed):

```sh
just osc-send 0.75                            # default port 7000, /v0/outgain/0
just osc-send 0.5 7001 127.0.0.1 /v0/lpf/0    # explicit value/port/host/address
python3 tools/send_osc.py --port 7000 --address /v0/outgain/0 --value 0.75
```

OSC arbitration smoke (multi-producer + ingress arbitration):

```sh
just session-osc-arbitration-smoke 10 7001
just session-osc-arbitration-send-claimed 0.5 7001
just session-osc-arbitration-send-allowed 0.5 7001
```

`osc-tool-test` is a unit smoke for the Python helper itself.

## A.6 MIDI session smokes

```sh
just session-midi-smoke 10                   # 10-second session MIDI ingress probe
just session-midi-smoke-device 2 10          # device index 2, 10 seconds
```

Used to verify the PortMIDI-backed source factory end-to-end against
a real controller. The `--midi-list` recipe enumerates devices first
if you don't know the name.

## A.7 Manifest authoring and planning (offline)

These are deterministic, non-audio. They construct, validate, or
diff manifest documents and reload plans without opening a runtime.

```sh
stack exec -- metasonic-bridge --authoring-manifest
stack exec -- metasonic-bridge --manifest-reload-plan DEMO_KEY
stack exec -- metasonic-bridge --manifest-reload-plan-file MANIFEST.json DEMO_KEY
stack exec -- metasonic-bridge --manifest-session-smoke MANIFEST.json DEMO_KEY
stack exec -- metasonic-bridge --manifest-stopped-audio-reload-smoke MANIFEST.json DEMO_KEY
```

The blessed fixtures live in [examples/manifests/](../examples/manifests/):

- `preserve-cutoff.json` — happy preserving reload (KLPF cutoff
  parameter change preserves voices).
- `reject-preserving-smooth.json` — KSmooth voice template; the
  reload is rejected by design because the active voice is
  preserve-unsupported.

## A.8 Manifest reload — host-level smoke (offline)

Runs the reload orchestration end-to-end with a fake audio host
(deterministic; safe in CI).

```sh
stack exec -- metasonic-bridge --manifest-host-reload-smoke \
  STRATEGY MANIFEST.json DEMO_KEY
```

`STRATEGY` is one of `stopped-audio-only`, `try-preserving`,
`require-preserving`. Renders a compact `reload events:` block beside
the fake audio events.

## A.9 Manifest reload — live (audible)

Two operator surfaces, both opening real PortAudio + real OSC.
Neither is part of `check-offline`; they are device-dependent.

**Two-shot demo** (OLD → wait → reload → NEW → wait → exit). Takes
two demo keys positionally — the starting demo and the target:

```sh
stack exec -- metasonic-bridge --manifest-live-reload-demo \
  STRATEGY MANIFEST.json OLD NEW
```

Example against the blessed preserving fixture:

```sh
stack exec -- metasonic-bridge --manifest-live-reload-demo \
  require-preserving examples/manifests/preserve-cutoff.json \
  preserve-cutoff-dark preserve-cutoff-bright
```

**Open-ended session shell** (operator stdin loop; supervisor
substrate consumer):

```sh
stack exec -- metasonic-bridge --manifest-live-session \
  MANIFEST.json DEMO_KEY [--strategy STRATEGY] [--session-osc-port PORT]
```

Default strategy is `require-preserving` (safest: never composes
with stopped-audio fallback). Stdin protocol: `demo:KEY` triggers
reload, `<Enter>` prints a status snapshot, `<Ctrl-D>` exits.
Operator-pass playbook in
[2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md).

**MIDI-driven reload smoke** (manual device probe):

```sh
stack exec -- metasonic-bridge --manifest-midi-reload-smoke \
  MANIFEST.json DEMO_KEY
```

## A.10 Live-audio wrappers (tier-2 marker smokes)

Each wrapper drives an `--manifest-live-reload-demo` or
`--manifest-live-session` invocation against a blessed fixture,
checks ~15–25 transcript markers including ingress / OSC / clean
exit / port rebind, and exits 0 only if every marker matched.

```sh
just manifest-supervised-live-smoke                          # stopped-audio-only,  port 17001
just manifest-supervised-try-preserving-live-smoke           # try-preserving,      port 17002
just manifest-supervised-require-preserving-live-smoke       # require-preserving,  port 17003
just manifest-live-session-require-preserving-smoke          # session, happy,      port 17004
just manifest-live-session-require-preserving-reject-smoke   # session, reject,     port 17005
```

Pass `port=N` to any of them to override the default port. All five
share `tools/manifest_*_live_smoke.sh` shape; the scripts themselves
are the source of truth for marker checks.

## A.11 C++ runtime direct

The C++ side has its own CMake build into `build-cpp/`. The
`rt_graph_smoke` executable links directly against the C ABI without
the Haskell layer; useful for hand-built graphs and reproducing
runtime issues without rebuilding GHC artifacts.

```sh
just cpp-configure              # cmake configure (Ninja, Debug)
just cpp-build                  # build everything
just cpp-lsp                    # symlink compile_commands.json so clangd works
just cpp-run                    # run rt_graph_smoke
just cpp-test                   # ctest all tests
just cpp-test-offline           # excludes start_audio / lifecycle live tests
just cpp-test-live              # only live audio lifecycle tests
just cpp-bench                  # §4.B kernel microbench (RelWithDebInfo)
just build                      # stack-build + cpp-build
```

The Haskell library also compiles the C++ sources via
`cxx-sources` in `package.yaml`; CMake's `build-cpp/` is separate
from `.stack-work/` and is what clangd reads.

## A.12 Verification gates

```sh
just check-offline              # git diff --check + stack-test + cpp-test-offline
just stack-test                 # Haskell test suite (parallel default)
just stack-test-serial          # serial escape hatch (PortAudio / worker pool)
just stack-test-parallel-asan   # AddressSanitizer + UBSan lane (isolated cache)
```

`check-offline` is the clean-checkpoint gate. It is device-free and
deterministic. The ASan lane uses `.stack-work-asan/` to avoid
contaminating the default build (see the `stack-build-asan` recipe
docs for the rationale).

---

# Part B. Haskell code surfaces

The pipeline is Haskell DSL → SynthGraph → GraphIR → RuntimeGraph →
C ABI → C++ DSP. Each stage is in a separate module under
[src/MetaSonic/Bridge/](../src/MetaSonic/Bridge/). The shortest
useful path through them is: build with the DSL, lower + compile,
load via FFI, start audio.

All examples assume:

```haskell
import Control.Concurrent (threadDelay)
import MetaSonic.Bridge.Source
import MetaSonic.Bridge.Templates (compileTemplateGraph)
import MetaSonic.Bridge.FFI
  (withRTGraph, loadTemplateGraph, startAudio, stopAudio)
```

`BuilderCapacity`, `MaxFrames`, and `TimeoutMs` are type aliases
for `Int` in `Bridge.FFI` — they document the role of adjacent
integer arguments, but you pass plain integer literals; there is no
constructor wrapping required.

## B.1 Minimal synth: write, compile, play

```haskell
simpleSine :: SynthGraph
simpleSine = runSynth $ do
  osc <- sinOsc (Param 440) (Param 0)
  out 0 =<< gain osc (Param 0.2)

main :: IO ()
main = do
  template <- either error pure $
    compileTemplateGraph [("simple-sine", simpleSine)]
  withRTGraph 64 512 $ \rt -> do
    loadTemplateGraph rt template
    _ <- startAudio rt 2 (-1)        -- 2 output channels, default device
    threadDelay (2 * 1000 * 1000)    -- play for 2 seconds
    stopAudio rt
```

That is the entire pipeline:

1. `runSynth` builds a `SynthGraph` (source-level vocabulary:
   `UGen`, `Connection`). Constants enter the graph as `Param x`,
   the `Connection` constructor for scalar literals.
2. `compileTemplateGraph` runs validation, lowering, region
   formation, and dense compilation, returning a `TemplateGraph`.
3. `withRTGraph` allocates a runtime; `loadTemplateGraph` walks the
   dense form across the FFI; `startAudio rt outChannels deviceID`
   opens PortAudio. The two arguments have independent inference
   thresholds: `outputChannels <= 0` asks the runtime to infer the
   channel count from configured `Out` buses; `deviceID < 0` asks
   the runtime to choose a default output device. The example above
   passes `2` and `-1`, so it requests 2 channels explicitly *and*
   the default device. The app's `oscOutputChannels = 2`,
   `oscDeviceID = -1` in
   [app/MetaSonic/App/Osc.hs](../app/MetaSonic/App/Osc.hs) is the
   canonical example of the same shape.

`Param` is the scalar-constant `Connection` constructor; numeric
literals get wrapped in `Param` as in the example above. The full
DSL surface lives in
[src/MetaSonic/Bridge/Source.hs](../src/MetaSonic/Bridge/Source.hs)
— read the module for the complete user-facing vocabulary.

## B.2 DSL vocabulary (cheat sheet)

All builders live in
[src/MetaSonic/Bridge/Source.hs](../src/MetaSonic/Bridge/Source.hs)
and return `SynthM Connection` (or `SynthM ()` for sinks).

**Oscillators.** `sinOsc freq phase`, `sawOsc freq phase`,
`pulseOsc freq phase width`, `triOsc freq phase`, `noiseGen`.

**Filters.** `lpf sig freq q`, `hpf sig freq q`, `bpf sig freq q`,
`notch sig freq q`.

**Arithmetic.** `gain sig amount`, `add a b`.

**Envelopes / delay / smoothing.** `env gate a d s r`,
`delayL maxDelaySeconds sig delayTime` (the underlying
`q::fractional_ring_buffer` is sized at template compile time from
`maxDelaySeconds`; there is no feedback or wet/dry mix in the DSL
helper — combine `delayL` with `gain` and `add` for those),
`smooth baseHz v`.

**Buses.** `out channel src` (hardware output), `busOut bus src`,
`busIn bus`, `busInDelayed bus` (one-block-delayed read; the only
way to express bus-level feedback without forcing same-block
ordering).

**Buffers / spectral / plugin.**
`playBufMono buf rate startFrame loopFlag`,
`recordBufMono buf signalIn loopFlag`,
`spectralFreeze signalIn freezeFlag`,
`staticPlugin ref in0 in1`.

**Controls and identity.** `cc num initial mn mx` declares a
named control input that auto-inserts a `KSmooth` at ingress;
`tagged "key" action` attaches a migration key to a node so its
state survives hot-swap.

## B.3 Multi-template ensembles

`compileTemplateGraph :: [(String, SynthGraph)] -> Either String TemplateGraph`
accepts an ordered list of named templates. Inter-template
ordering is derived from each template's `BusFootprint`
(writes / live-reads / delayed-reads); cycles produce a compile
error.

```haskell
template <- either error pure $ compileTemplateGraph
  [ ("voice", voiceGraph)   -- writes bus 7
  , ("fx",    fxGraph)      -- live-reads bus 7, writes channel 0
  ]
```

The voice runs before fx automatically. Look at the `send-return`
demo in `app/Main.hs` for a real example.

## B.4 Single-graph compilation (without the template layer)

For one-off graphs or test fixtures:

```haskell
import MetaSonic.Bridge.IR (lowerGraph)
import MetaSonic.Bridge.Compile (compileRuntimeGraph)
import MetaSonic.Bridge.FFI (loadRuntimeGraph)

runtime <- either error pure $ do
  ir <- lowerGraph simpleSine
  compileRuntimeGraph ir
withRTGraph 64 512 $ \rt -> do
  loadRuntimeGraph rt runtime
  -- ...
```

`loadRuntimeGraph` is the lower-level single-template path;
`loadTemplateGraph` is the multi-template wrapper that calls it
internally. Most production code goes through the template path
because identity / ensemble precedence comes for free.

## B.5 Hot-swap a live graph

The runtime has an RCU swap protocol (Phase 5). A producer builds a
next-world graph offline and publishes it; the audio thread
installs at a block boundary; the old world is retired and reaped
off-audio.

```haskell
import MetaSonic.Bridge.FFI
  ( hotSwapTemplateGraph, hotSwapTemplateGraphAndWait
  , waitForSwapGeneration, collectRetiredSwapStats
  )

-- Live producer: publish + wait + reap stats.
-- Signature: rt -> capacity -> maxFrames -> timeoutMs -> templateGraph.
result <- hotSwapTemplateGraphAndWait rt 64 512 250 nextTemplateGraph
```

The `*AndWait` variants publish, block until the install generation
advances (with the given timeout), reap migration stats, and return.
The non-blocking variants return immediately and require explicit
`waitForSwapGeneration` + `collectRetiredSwapStats`.

State migration: per-node `tagged "key"` migration keys survive
lowering and FFI loading. The audio-thread install loop copies
matched controls and copy-safe DSP state. Env / Delay / Smooth
default-init across swaps (Phase 5.2 footnote — prewarm slice not
landed yet).

Identity precondition: each template's `tplName` ships through the
ABI as a 16-byte identity token. Reordering templates across a swap
fails the prepare step with no install (Phase 5.4.B).

## B.6 Manifest construction and reload

Authoring manifests bridge the runtime API and an external,
file-based plan vocabulary used by the live session.

The blessed v1 surface is in
[app/MetaSonic/App/](../app/MetaSonic/App/) under the
`ManifestReload*` module family, with the session counterpart at
[app/MetaSonic/App/ManifestLiveSession.hs](../app/MetaSonic/App/ManifestLiveSession.hs).
(Application-layer modules live under `app/`, not `src/` — `src/`
holds the library DSL and compiler stages only.)
The shortest entry points:

```haskell
import MetaSonic.App.ManifestLiveCommon
  (readManifestDocOrDie, planOrDie)
import MetaSonic.App.ManifestReloadSupervisor (reloadSupervised)
```

For programmatic reload from another Haskell process, read the
session shell as the worked example — it is the smallest real
consumer of the supervisor substrate.

## B.7 Voice allocator and MIDI

The voice allocator and MIDI dispatch live in C++
(`tinysynth/voice_allocator.cpp`,
`tinysynth/midi_voice_processor.cpp`). Haskell does not send MIDI
events to the runtime; the C++ side owns live note lifetimes. The
Haskell-side interaction is through the realtime control queue, the
template / instance ABI, and (for tests) the test-only
introspection surface in `rt_graph_test_*`.

Read [src/MetaSonic/Bridge/FFI.hs](../src/MetaSonic/Bridge/FFI.hs)
for the full FFI vocabulary including test entry points; the C ABI
in [tinysynth/rt_graph.h](../tinysynth/rt_graph.h) is the
single source of truth for what crosses the boundary.

---

# Part C. Self-discovery

When this note goes stale, here is how to find the current truth:

- **CLI flags.** Search `app/Main.hs` for `go opts (...)`. Each arm
  matches a flag; the second positional often documents the help
  shape.
- **`just` recipes.** `just --list` enumerates them with the
  one-line comment header. The recipe body is the literal command.
- **DSL builders.** Grep `^[a-zA-Z]+ ::` in
  `src/MetaSonic/Bridge/Source.hs`. Anything top-level and exported
  is part of the user surface.
- **FFI entry points.** Same grep against
  `src/MetaSonic/Bridge/FFI.hs`. The C side is in
  `tinysynth/rt_graph.h`.
- **What's tested.** `test/Spec.hs` is the entry point. Module
  names follow `MetaSonic.Spec.*` and mirror the source layout.
- **What's blessed for live reload.** `examples/manifests/`.
- **What's still open vs frozen.** `ROADMAP.md` (long; grep for the
  phase number you care about).

---

# Part D. Worked-example pointers

Rather than embed long examples here, point at the existing ones:

- **Simple subtractive voice with envelope and delay:**
  [app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs) —
  search for `chainGraph`, `envPluckGraph`.
- **Multi-template send/return:**
  [app/MetaSonic/App/Demos.hs](../app/MetaSonic/App/Demos.hs) —
  the `sendReturnEnsemble` / `sendReturnVoice` / `sendReturnFx` /
  `sendReturnDemo` cluster; `sendReturnDemo` is what the
  `send-return` CLI key compiles.
- **MIDI poly voice:** the `midi-poly` demo, end-to-end including
  the C++ voice allocator side.
- **Hot-swap with tagged migration:** the `--swap-bench` corpus in
  [app/MetaSonic/App/SwapBench.hs](../app/MetaSonic/App/SwapBench.hs).
- **Manifest-driven live session:** the v0 design note
  [2026-05-20-b-manifest-live-session-v0.md](2026-05-20-b-manifest-live-session-v0.md)
  and the playbook
  [2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md).
- **Reject-path operator narrative:**
  [2026-05-21-a-reject-path-operator-pressure-pass.md](2026-05-21-a-reject-path-operator-pressure-pass.md).

If you wrote a new demo or worked example that is general-purpose,
adding it to this list keeps the note useful.
