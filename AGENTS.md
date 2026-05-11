# Repository Guidelines

## Build And Tooling

- Haskell package metadata is generated from `package.yaml` by hpack. Edit
  `package.yaml`; do not hand-edit `metasonic-bridge.cabal`.
- The C++ runtime is built through two independent paths:
  - `package.yaml` via `cxx-sources`, for `stack build` and the Haskell
    executable/tests.
  - `CMakeLists.txt`, for `build-cpp/`, clangd, `rt_graph_smoke`, and C++
    tests.
- When changing C++ sources, headers, include paths, or linked libraries, keep
  both `package.yaml` and `CMakeLists.txt` in sync.
- The C++ runtime is C++20 and depends on system `portaudio` and `portmidi`.
- `vendor/q` and `vendor/infra` are required submodules.

Common commands:

```sh
just stack-build
just stack-test
just cpp-build
just cpp-run
just cpp-test
just build
```

Use `just metasonic-help` to list demo graphs. Use `just metasonic NAME`,
`just metasonic-inspect NAME`, or `just metasonic-inspect-only NAME` for
runtime and inspector workflows.

## Architecture

This repository is the bridge layer of MetaSonic:

```text
Haskell DSL -> SynthGraph -> GraphIR -> RuntimeGraph -> DSP Engine
```

Read pipeline modules in this order:

1. `src/MetaSonic/Types.hs`
2. `src/MetaSonic/Bridge/Source.hs`
3. `src/MetaSonic/Bridge/Validate.hs`
4. `src/MetaSonic/Bridge/IR.hs`
5. `src/MetaSonic/Bridge/Compile.hs`
6. `src/MetaSonic/Bridge/FFI.hs`

`NodeID` is symbolic and compile-time only. `NodeIndex` is dense, ordered, and
crosses the FFI boundary. Do not collapse that distinction.

## Haskell/C++ Boundary

The C ABI lives in `tinysynth/rt_graph.h`; the implementation lives in
`tinysynth/rt_graph.cpp`. `src/MetaSonic/Bridge/FFI.hs` is the Haskell crossing
point.

When adding or changing a runtime node kind, update both sides in lockstep:

- `src/MetaSonic/Types.hs`: add the `NodeKind` constructor and `kindSpec` row.
- `src/MetaSonic/Bridge/Source.hs`: add the `UGen`, `ugenView` row, and
  user-facing builder.
- `tinysynth/rt_graph.cpp`: update `NodeKind`, `kind_from_tag`, node
  configuration/state, the processing function, and `process_graph`.
- Tests should cover arity/tag drift and any C++-only DSP behavior.

Current tag contract (canonical source: `kindSpec` in `src/MetaSonic/Types.hs`):

```text
KSinOsc        1
KOut           2
KGain          3
tag 4          intentionally unused
KSawOsc        5
KNoiseGen      6
KLPF           7
KAdd           8
KEnv           9
KBusOut       10
KBusIn        11
KBusInDelayed 12
KDelay        13
KSmooth       14
KPulseOsc     15
KTriOsc       16
KHPF          17
KBPF          18
KNotch        19
KPlayBufMono   20
KRecordBufMono 21
KSpectralFreeze  22
KStaticPlugin  23
```

`test/Spec.hs` checks Haskell-side structural invariants, dense lowering,
region invariants, FFI smoke behavior, and the `kindTag`/C++ support contract.
`tests/rt_graph_test.cpp` covers C++ runtime behavior that Haskell tests cannot
see directly.

## Runtime Notes

- `loadRuntimeGraph` calls `rt_graph_clear`; the current reload path stops
  active audio, clears nodes/buses, and rebuilds. Do not describe this as
  uninterrupted hot swapping.
- Runtime DSP is intentionally simple: C++ iterates dense nodes in storage
  order, which must already be topologically valid from the Haskell compiler.
- q_lib stateful DSP should preserve runtime state where possible. Reconfigure
  coefficients or parameters without reconstructing state unless a reset is
  explicitly intended.

## Working Rules

- Keep edits narrowly scoped to the requested change.
- Do not revert unrelated dirty worktree changes.
- Do not commit or stage unless explicitly asked.
- Ignore generated/build artifacts such as `build/`, `build-cpp/`,
  `.stack-work/`, and generated `.cabal` files.
- After C++ structural changes, run `just cpp-configure` or `just cpp-lsp` so
  `compile_commands.json` is refreshed for clangd.
