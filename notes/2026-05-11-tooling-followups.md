# Tooling Follow-Ups After The First Offline Check Slice

Date: 2026-05-11

This note captures the tooling ideas that were useful but not simple enough to
bundle with the first implementation slice.

## Landed In The Simple Slice

- `just cpp-test-offline`: runs the C++ doctest suite while excluding tests
  that call `rt_graph_start_audio`.
- `just cpp-test-live`: runs the device-backed realtime-audio tests only.
- `just check-offline`: runs `git diff --check`, `just stack-test`, and the
  offline C++ suite.
- `metasonic-bridge --plugin-list`: prints the build-linked static plugin
  registry used by `KStaticPlugin`.
- Static plugin registry metadata is now visible through the C ABI and pinned
  by Haskell and C++ tests.

## Deferred: CTest / Doctest Labels

The regex split in `just cpp-test-offline` is intentionally small. The stronger
version is to label tests at the doctest/CTest layer:

- label device-backed tests as `live-audio`;
- label deterministic tests as `offline`;
- route `just cpp-test-offline` through label exclusion instead of name regex;
- keep `just cpp-test` as the full suite.

This is worth doing if the live-audio group grows or if test names become too
fragile to use as routing metadata.

## Deferred: Survey Snapshot Checker

A useful next tool is a deterministic survey snapshot checker that runs:

- `metasonic-bridge --fusion-survey`;
- `metasonic-bridge --corpus-survey`;
- selected grep-friendly assertions over kernel totals, missed-shape rows,
  declared-latency rows, and corpus coverage.

Do not make this a byte-for-byte golden file at first. The surveys are
decision inputs, so the checker should pin the invariants that would change a
roadmap decision while allowing harmless formatting changes.

## Deferred: `metasonic-doctor`

`metasonic-doctor` should be a read-only environment probe, not a build step.
Useful checks:

- report Stack resolver / GHC visibility;
- report CMake and Ninja availability;
- report PortAudio / PortMIDI library discovery;
- report submodule status for `vendor/q` and `vendor/infra`;
- report whether `build-cpp/compile_commands.json` is current enough for
  clangd workflows;
- print which deterministic and live checks are available on this machine.

Keep it separate from `check-offline`; a doctor command should diagnose setup,
not decide whether a source commit is correct.

## Deferred: Plugin Contract Checker

The first `--plugin-list` is an inspection surface. A later checker should
validate all build-linked plugin rows before audio starts:

- unique non-empty names;
- arity matches the Haskell `PluginRef` catalog for exposed plugins;
- declared latency is non-negative and round-trips through the §6.D latency
  reporting path;
- state size is aligned and matches init/reset/process expectations;
- effect declarations, once plugin effects grow beyond `Pure`, feed the
  §6.C.4 / §6.C.5 resource ordering rules.

This belongs near the next Phase 6.E slice that introduces a real plugin call
path or a second plugin row.
