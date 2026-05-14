# Phase 5.4 - Producer Identity After Install

Date: 2026-05-10
Status: 5.4.A design landed; 5.4.B template identity precondition
implemented (rt_graph_template_set_identity ABI, prepare-time live-slot
check, Haskell loaders set the token from tplName). 5.4.C/D remain
deferred until a real producer surfaces friction.

Phase 5.2 solved identity for the runtime migration pass: during
`prepare_swap_from_graph`, the old world and new world are matched by
`template_id`, live instance slot, and caller-supplied node migration
keys. That mapping is internal to the C++ install loop. It tells the
runtime what state to copy; it does not tell a producer which handles it
should use after the new world becomes active.

The producer-side question is different:

> After publish, install, and collect, how does a live caller retarget
> UI sliders, MIDI bindings, bus controls, and template-scoped commands
> to the new world?

This note pins the v1 split between producer-owned identity and
runtime-enforced preconditions before any 5.4 code lands.

## 1. Node identity surface

### Decision

The v1 producer owns node-key resolution. Do not add a C ABI that asks a
retired `RTGraphSwap` or active `RTGraph` to resolve:

```text
(template_id, migration_key) -> new NodeIndex
```

The producer just compiled the new `RuntimeGraph` or `TemplateGraph`.
That compile product already contains the new dense `NodeIndex` values
and each node's optional `MigrationKey`. A producer that wants a stable
slider target should build its post-swap table from the new compile
product before publish, wait until `swap_generation` advances, then
switch its UI/control routing to the new table.

### Why

- The C++ runtime intentionally has no user-facing node-name map.
- `NodeIndex` is a dense per-compile ordinal; exposing a runtime lookup
  would make the C ABI own producer tooling concerns.
- The Haskell side has stronger types and the full compile artifact.
  A pure helper can build a `MigrationKey -> NodeIndex` table without
  touching the audio runtime.

### Possible Haskell helper

If a second producer needs it, add a small pure helper rather than a C
ABI:

```haskell
runtimeMigrationIndex
  :: RuntimeGraph
  -> MigrationKey
  -> Maybe NodeIndex

templateMigrationIndex
  :: TemplateGraph
  -> String          -- template name
  -> MigrationKey
  -> Maybe NodeIndex
```

The helper should reject duplicate keys the same way validation already
does. It is producer ergonomics, not a runtime safety boundary.

## 2. Bus identity across swap

### Decision

For v1, bus index is the identity. There is no bus migration key and no
runtime bus-name map.

The caller is responsible for keeping bus indices stable across the
swap. If a graph used bus 5 for a delayed feedback loop before publish,
the post-swap graph must still use bus 5 for that semantic signal.
Phase 5.2 already commits that bus contents are not migrated; the new
world's bus storage starts fresh.

### Why

- Bus ids are already explicit numeric controls at the DSL/runtime
  boundary.
- Preserving or remapping bus contents requires a bus-count
  reconciliation rule, which is a different feature from producer
  retargeting.
- A named-bus layer can be added on the Haskell side later and resolved
  to numeric buses before FFI loading, without changing the C runtime.

### Non-goals

- No `BusKey` in 5.4.
- No preservation of `output_buses_prev` in 5.4.
- No automatic bus remap in `prepare_swap_from_graph`.

## 3. Template identity and renumbering

### Problem

State migration and live-instance lifecycle migration assume that
`template_id` names the same semantic template in the old and new
worlds. The current code treats that as producer discipline. That is
too weak for hot-swap: reordering two templates can make slot-index
migration copy state into the wrong semantic template while still
looking structurally valid to the runtime.

Unlike node-key lookup and bus naming, this is a runtime safety
precondition. The audio-thread install loop cannot safely migrate live
slot state if the producer silently renumbered templates.

### Decision

Make semantic template-id stability enforceable before publish.

The runtime needs a per-template identity token on `MetaDef`. Haskell
template loaders should set it from `tplName`; single-template
`RuntimeGraph` loaders can set a fixed default token for template 0 or
leave the token absent. `prepare_swap_from_graph` should reject a
prepared swap when an old live slot's `template_id` maps to a new
template with a different identity token.

The exact C representation is an implementation detail. It can mirror
node migration keys: fixed-width non-NUL bytes, populated by a
construction-path ABI, and compared off-audio while building the swap
plan.

### Scope of the check

The check should focus on ids that can affect migration:

- old instance slot is Active or Releasing;
- old slot has `template_id = tid`;
- new world has a slot `tid` or template `tid` that migration would use;
- both old and new templates have identity tokens;
- tokens differ -> prepare fails.

If either side lacks a token, direct C callers keep today's permissive
behavior. The Haskell loaders should set tokens so Haskell hot-swap gets
the stronger contract by default.

### Why not Haskell-only?

Haskell can compare `TemplateGraph` names if the producer retains both
old and new compile artifacts. The runtime still needs the guard because
direct C callers and future producer helpers can otherwise bypass the
discipline. This is the one part of producer identity where the runtime
should say "no" instead of relying on out-of-band knowledge.

## 4. Proposed 5.4 slices

### 5.4.A - Design-only slice

This note. No runtime behavior change.

### 5.4.B - Template identity precondition (done)

Implemented as designed. Concretely:

- `MetaDef::identity` is a fixed 16-byte token (the same `MigrationKey`
  shape Phase 5.2 already uses for nodes, repurposed per-template).
- `rt_graph_template_set_identity(g, template_id, key, key_len)` is the
  construction-path setter; setter validation matches the node setter
  (1..16 bytes, no NUL, valid `template_id`). Identity is single-valued
  per template — overwriting is allowed and intentional.
- `loadTemplateGraph` and `loadTemplateGraphFused` ship `tplName` as
  the identity. Names that exceed 16 UTF-8 bytes or contain NUL fail
  during the pre-clear validation gate, so the producer sees the
  contract violation up front and the currently loaded graph is
  preserved.
- `rt_graph_prepare_swap_from_graph` runs
  `template_identity_precondition_ok` before allocating a swap. Walk
  every Active or Releasing old instance, look up
  `defs[template_id]` in both old and new state; if both have an
  identity and they differ, return `nullptr`. Empty tokens on either
  side opt out.
- Templates with no live slot are not checked. A renumber that happens
  before any voice is active is not observable through migration; the
  rejection rule is scoped to the live-slot case so dormant pools stay
  rebuilable.

Tests:

- C++ doctests (5 cases): setter validation; matching tokens succeed;
  differing tokens reject; missing token on one side stays permissive;
  differing tokens with no live slot still succeed.
- Haskell (4 cases): same-name same-order swap publishes and migrates
  two lifecycle copies; reordered named-template swap rejects before
  install (no generation advance, no retired swap), and a same-shape
  recovery publish afterwards still works; overlong template identity
  fails before `c_rt_graph_clear`; fused-template reorder rejects on
  the fused loader path.

The single-template `loadRuntimeGraph[Fused]` path deliberately does
not set an identity. The flat graph has only `template_id 0`; with
nothing to disambiguate, the precondition has nothing to enforce. The
setter is available for any caller that wants stricter behavior on the
flat path.

### 5.4.C - Optional producer-side mapping helpers

Only if a caller needs them:

- Add pure Haskell helper(s) that build a post-swap table from a
  `RuntimeGraph` or `TemplateGraph`.
- Do not add C ABI unless the Haskell helper proves insufficient.

### 5.4.D - Bus naming, deferred

Only if real producer code starts passing raw bus numbers around in a
way that becomes error-prone. The first version should be Haskell-only:
named buses resolved to numeric bus ids before FFI loading.

## 5. Summary

- Node retargeting is producer-owned: derive it from the new compile
  product.
- Bus identity is numeric and caller-owned in v1.
- Template-id semantic stability is runtime-safety-critical and should
  become a prepare-time precondition.
