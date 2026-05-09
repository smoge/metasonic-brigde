# MetaSonic Bridge

Graph compiler and FFI layer for the MetaSonic audio system.

MetaSonic is a research project exploring compiler architecture for real-time
signal graphs with deterministic execution semantics. This repository —
`metasonic-bridge` — is a prototype implementation of its core pipeline:
representing audio graphs in a strongly typed IR, stripping redundant nodes,
and marshaling the result across a thin FFI boundary into C++.

The source is documented with Haddock comments and cross-reference notes that
cover significantly more detail than this file. For a conceptual picture of the
system, read the code in pipeline order starting from
[`src/MetaSonic/Types.hs`](./src/MetaSonic/Types.hs).

For deeper design discussion and reasoning, see the [blog](https://smoge.github.io/metasonic-bridge).

```
Haskell DSL → SynthGraph → GraphIR → RuntimeGraph → DSP Engine
```

No symbolic lookups in the audio thread. No runtime graph solving.
Everything is resolved before the C++ layer sees it.

---

## Motivation

At this development stage, graph building is a compiler problem. DSP is a
runtime problem. Two worlds:

- **Haskell** — builds, analyzes, compiles
- **C++20** — executes DSP, deterministic and strict

You don't evaluate structure at runtime. You build, validate, order, compile —
then execute. When audio starts, decisions are already made.

Note: planned changes include adding and modifying graphs without interrupting
audio. This will require some changes in the C ABI.

---

## Architecture

`metasonic-bridge` is one layer of a larger system. Each layer can be developed
and tested independently:

```
metasonic-core       DSL — no C++ dependencies, pure Haskell
     ↓
metasonic-bridge     graph compiler+FFI+TUI inspectior
     ↓
tinysynth            real-time audio engine — pure C++20 + q_lib 
     ↓
tinysynth-ui         runtime-facing UI on the C++ side 
```

- **metasonic-core** defines the user-facing DSL. No FFI involvement. Type
  discipline is the bridge's responsibility, not the DSL's.
- **metasonic-bridge** compiles graphs into a strongly typed IR and
  marshals across the FFI boundary.
- **tinysynth** is the audio engine. Plugins are authored and tested entirely in
  C++ — no Haskell toolchain required.
- **tinysynth-ui** provides real-time parameter control and audio visualization
  through Dear ImGui. It links tinysynth directly for the hot path (knobs,
  meters, FFT display) and `dlopen`s the bridge shared library for structural
  operations (graph editing, recompilation).

The modules in this repository roughly correspond to stages in the compilation
pipeline. The bridge requires that the Haskell and C++ sides stay in sync —
particularly when new tinysynth plugins are introduced — though there are plans
to derive more of this synchronization from plugin metadata.

As the system stabilizes, all layers will live in a single monorepo while
keeping their architectural modularity. This repo layout is temporary.

---

## Quick start

### Requirements

- **GHC** — tested with 9.10.3
- **Stack** — deterministic dependency management
- **C++20 compiler** — GCC or Clang
- **PortAudio** — must be installed separately on your system
- **Q** (C++20 library) — infra and q_lib modules, included as git
  submodules

### Build and run

```sh
git clone --recurse-submodules https://github.com/smoge/metasonic-bridge.git
cd metasonic-bridge
stack build
stack exec metasonic-bridge
```

---

## Usage

The executable supports five run modes and an optional set of demo targets.

```
stack exec -- metasonic-bridge [MODE] [DEMO ...]
```

### Run modes

| Flag               | Behavior                                               |
|--------------------|--------------------------------------------------------|
| *(default)*        | Compile and play audio directly                        |
| `--inspect`        | Open the TUI pipeline inspector, then play audio       |
| `--inspect-only`   | Open the TUI pipeline inspector, skip audio            |
| `--fusion-survey`  | Compile demos through both runtime paths and report    |
|                    | fusion coverage and corpus FreeLayer-width             |
| `--worker-bench`   | Compile demos plus the fixed corpus and benchmark      |
|                    | the schedule worker dispatch path                      |

### Demo targets

If no demo names are given, all available demos run in sequence.

To list the available `SynthGraph`s, run:

```sh
stack exec -- metasonic-bridge --help
```

### Examples

```sh
# Play all (audio only)
stack exec -- metasonic-bridge

# Play a specific SynthGraph
stack exec -- metasonic-bridge chain

# Inspect a graph with TUI, then play audio
stack exec -- metasonic-bridge --inspect chain

# Inspect all graphs with no audio
stack exec -- metasonic-bridge --inspect-only

# Inspect a specific graph
stack exec -- metasonic-bridge --inspect-only fanout
```

### Compilation inspector (TUI)

The `--inspect` and `--inspect-only` flags launch a terminal UI built with brick
that lets you step through every stage of the compilation pipeline for each demo
graph. When using `--inspect`, the inspector runs for each demo graph in
sequence. After exiting the inspector (`q` or `Esc`), a compilation summary
prints to stdout and audio begins. With `--inspect-only`, audio is skipped
entirely.

![TUI Inspector](./img/tui-inspector.png)

---

## SynthGraph syntax

The DSL for building graphs looks like this (these are some of the
included demos, one can play audio and inspect each one via TUI):

```haskell
chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

sawGraph :: SynthGraph
sawGraph = runSynth $ do
  osc <- sawOsc 440.0 0.0
  g   <- gain osc 0.4
  out 0 g

noiseGraph :: SynthGraph
noiseGraph = runSynth $ do
  n <- noiseGen
  g <- gain n 0.15
  out 0 g

noiseLpfGraph :: SynthGraph
noiseLpfGraph = runSynth $ do
  n <- noiseGen
  f <- lpf n 800.0 0.7
  g <- gain f 0.4
  out 0 g

filteredSawGraph :: SynthGraph
filteredSawGraph = runSynth $ do
  osc <- sawOsc 110.0 0.0
  f   <- lpf osc 1200.0 1.5
  g   <- gain f 0.6
  out 0 g

detunedSawGraph :: SynthGraph
detunedSawGraph = runSynth $ do
  osc1 <- sawOsc 220.0 0.0
  osc2 <- sawOsc 220.5 0.5
  g1   <- gain osc1 0.3
  g2   <- gain osc2 0.3
  out 0 g1
  out 0 g2

```

This syntax belongs to `metasonic-bridge` — the compilation layer that
constructs IR nodes and lowers them to C++. The authoring DSL in
`metasonic-core` sits above this, offering alternative interfaces.

---

## Current state

- Block-based DSP execution
- Static, precompiled graphs
- DSP layer grounded on q_lib
- Minimal node set (tinysynth includes q_lib "plugins" and will extend it)
- TUI inspector for stepping through compilation stages (use command-line options)
- Survey/benchmark reporting modes for fusion coverage and schedule worker dispatch

