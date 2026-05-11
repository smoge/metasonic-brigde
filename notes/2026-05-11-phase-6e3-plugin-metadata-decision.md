# Phase 6.E.3 Plugin Metadata Decision

Date: 2026-05-11

Status: decision artifact for the next static-plugin slice. No runtime
or C ABI behavior changes are made by this note.

## Decision

Use a Haskell-side per-plugin metadata table.

Keep `KStaticPlugin` as the only plugin `NodeKind` for now. Add a
small catalog keyed by `PluginRef` that records each build-linked
plugin's frozen integer id, audio input/output arity, declared
latency, resource effects, and display label. The existing fixed
`Identity` plugin becomes the first row in that catalog.

This keeps the C ABI narrow while allowing plugin facts to become
plugin-specific on the compiler side:

- `staticPluginId` should become a lookup into the catalog.
- `checkStaticPluginRefs` should validate through the catalog.
- `inferEff (StaticPlugin ref _ _)` should use the catalog's effects.
- latency reporting can gain a plugin-aware path without pretending
  all `KStaticPlugin` nodes have the same latency.
- resource-footprint extraction can pick up plugin bus/buffer effects
  once a non-pure plugin row exists.

The key design point is that the audio thread still sees a frozen
`plugin_id` control and dense input/output buffers. It does not learn
symbolic plugin names, arity rules, latency declarations, or resource
effects at process time.

## Alternatives Rejected For Now

### One `NodeKind` per plugin profile

This would preserve the current kind-level tables, but it would make
every new static plugin look like a new built-in node. That is too
heavy for the next step and blurs the distinction between the plugin
host and native runtime kinds.

### RuntimeNode metadata extension

Moving arity, latency, and effects onto `RuntimeNode` is the most
general answer. It may still be the right long-term direction for
generated fusion and richer authoring-level expansion, but it is too
large for 6.E.3. It would touch the IR, FFI payload, inspector/survey
code, and runtime loading path before a second plugin has proven the
need.

## Initial Scope

The implementation slice after this note should be Haskell-only unless
tests expose a registry mismatch:

1. Add a plugin metadata catalog near `PluginRef`.
2. Route `identityPlugin` / `staticPluginId` through the catalog.
3. Add helper accessors for arity, declared latency, and effects.
4. Update static-plugin validation tests to assert the catalog row.
5. Keep the existing C++ static registry unchanged.

The first catalog row is:

```text
name            identity
plugin_id       0
audio_inputs    2
audio_outputs   1
latency         0
effects         Pure
```

No second plugin lands in this slice.

## Non-Goals

- LV2, VST3, CLAP, AU, or dynamic loading.
- Plugin discovery.
- Plugin-owned UI.
- MIDI-in plugins.
- Parameter layout or modulation.
- Plugin state migration.
- New C ABI surface.

Those reopen only after a real second static plugin proves which
metadata path is actually load-bearing.
