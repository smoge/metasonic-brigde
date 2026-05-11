# Phase 7.B Fusion Legality and Capability Metadata Decision

Date: 2026-05-11

Status: decision artifact for Phase 7.B. No runtime, C ABI, or
compiler-behavior change is made by this note; it specifies the table
the next implementation slice adds.

## Decision

Add a per-`NodeKind` **capability table** that classifies each kind
using **overlapping flags**, not a partition. The table is the
legality vocabulary that the cost lab, the Phase 7.C planner, and
session-layer scoping gate 1 will consume.

Six initial flags:

```haskell
data KindCapability
  = CapStatelessOp
  | CapStatefulOp
  | CapSinkTerminal
  | CapResourceAccess
  | CapLatencyBearing
  | CapHardBarrier
```

The table is stored as a separate function `kindCapabilities ::
NodeKind -> [KindCapability]` next to `kindSpec` / `kindLatency` in
`MetaSonic.Types`. It is **not** folded into `KindSpec`, for three
reasons:

1. `KindSpec` carries ABI tag, arity, rate, and label — the
   "what the C ABI sees" set. Capabilities are planner vocabulary;
   mixing the two would conflate roles.
2. The "effects are per-UGen, not per-kind" invariant in
   `Note [Effects are per-UGen, not per-kind]` in `Source.hs` is
   easier to keep honest with a separate kind-level table whose
   purpose is explicitly per-kind reasoning.
3. New planner-relevant flags can be added without touching the
   C ABI side or the existing kindSpec/ugenView agreement tests.

## Why Overlapping Flags, Not A Partition

Several kinds need multiple truths at once:

- `KOut` and `KBusOut` are sinks **and** bus writers.
- `KRecordBufMono` is stateful **and** a buffer writer.
- `KBusIn` is stateless **and** a resource reader.
- `KSpectralFreeze` is stateful **and** latency-bearing.

A partition would either force a single "primary" flag and lose
information, or invent compound flags (`CapStatefulSink`, etc.) that
re-encode the overlap. Overlapping flags keep the table small and
let each downstream consumer take the subset it cares about.

## Why Not Name It "Pure"

The repo already uses `Eff Pure` to mean "carries no Bus/Buffer
effect at the per-UGen level." That is **not** the same as "safe to
inline into a generated fusion program." `KSinOsc` is `Eff Pure` but
is `CapStatefulOp` because it carries phase across samples.
`KStaticPlugin`'s Identity row is a pure function of its inputs at
the math level but is `CapHardBarrier` from the planner's standpoint.

`CapStatelessOp` / `CapStatefulOp` describe cross-sample state;
`CapResourceAccess` covers resource I/O; per-UGen `inferEff` remains
the authority on **which** resource.

## Flag Definitions

### `CapStatelessOp`

The kind's output at sample `n` depends only on inputs at sample `n`.
Generated fusion may inline a stateless op into a larger program;
two stateless ops can be folded into a single instruction. The flag
is a legality necessary condition, not a sufficient one — the
planner still applies its own profitability gate.

### `CapStatefulOp`

The kind carries cross-sample state: filter z^-1 history, oscillator
phase, envelope phase, smoother coefficient state, delay-line
position, buffer playback or record position, spectral analysis
window. Generated fusion may fuse stateful ops as separate program
instructions but cannot collapse two stateful instances without
explicit state handling.

### `CapSinkTerminal`

Terminates a chain. Output never feeds further DSP. Fusion regions
may close on a sink terminal; nothing fuses past it on the consuming
side.

### `CapResourceAccess`

The kind reads from or writes to a Bus or a Buffer. The flag
declares the **possibility**; per-UGen `inferEff` declares which
specific resource. A `BusOut 5` and a `BusOut 7` share this
kind-level flag but differ in their per-UGen effect. This separation
keeps the kind-level table small and the per-UGen invariant intact.

### `CapLatencyBearing`

The kind declares non-zero latency via `kindLatency`. Generated
fusion cannot inline across a latency boundary without explicit
handling, and a latency-bearing kind contributes to total-latency
reporting. The capability is defined **precisely** as
`kindLatency k` returns `Just _`; this is a test-enforced biconditional
so the two tables cannot drift.

Currently only `KSpectralFreeze` qualifies (frame latency, 1024
samples). `KBusInDelayed` and `KDelay` are **not** `CapLatencyBearing`
today — see open questions below.

### `CapHardBarrier`

Opaque to the planner. Cannot be fused into, out of, or around.
Reserved for kinds whose internal semantics the planner does not
have enough metadata to reason about.

Currently only `KStaticPlugin` qualifies. Rationale: §6.E.3 chose a
Haskell-side per-plugin metadata catalog as the path to plugin-specific
fusion legality. Until that catalog grows beyond the lone `Identity`
row, `KStaticPlugin` stays a hard barrier. When a second static
plugin lands and the catalog is exercised, the right move is to
refine `KStaticPlugin`'s classification per-plugin via the catalog —
not to add new `NodeKind`s and not to surface plugin facts to the C
ABI.

`KSpectralFreeze` is intentionally **not** a hard barrier today. The
planner already sees its inputs and outputs at the buffer boundary;
`CapStatefulOp + CapLatencyBearing` is enough to express "do not
inline this into sample-rate fusion." If a later planner pass shows
it needs full opacity, it can graduate to `CapHardBarrier` then.

## Per-Kind Assignments

| `NodeKind`        | Capabilities                                                  |
|-------------------|---------------------------------------------------------------|
| `KSinOsc`         | `CapStatefulOp`                                               |
| `KOut`            | `CapSinkTerminal`, `CapResourceAccess`                        |
| `KGain`           | `CapStatelessOp`                                              |
| `KSawOsc`         | `CapStatefulOp`                                               |
| `KNoiseGen`       | `CapStatefulOp`                                               |
| `KLPF`            | `CapStatefulOp`                                               |
| `KAdd`            | `CapStatelessOp`                                              |
| `KEnv`            | `CapStatefulOp`                                               |
| `KBusOut`         | `CapSinkTerminal`, `CapResourceAccess`                        |
| `KBusIn`          | `CapStatelessOp`, `CapResourceAccess`                         |
| `KBusInDelayed`   | `CapStatelessOp`, `CapResourceAccess`                         |
| `KDelay`          | `CapStatefulOp`                                               |
| `KSmooth`         | `CapStatefulOp`                                               |
| `KPulseOsc`       | `CapStatefulOp`                                               |
| `KTriOsc`         | `CapStatefulOp`                                               |
| `KHPF`            | `CapStatefulOp`                                               |
| `KBPF`            | `CapStatefulOp`                                               |
| `KNotch`          | `CapStatefulOp`                                               |
| `KPlayBufMono`    | `CapStatefulOp`, `CapResourceAccess`                          |
| `KRecordBufMono`  | `CapStatefulOp`, `CapResourceAccess`                          |
| `KSpectralFreeze` | `CapStatefulOp`, `CapLatencyBearing`                          |
| `KStaticPlugin`   | `CapHardBarrier`                                              |

Every `NodeKind` carries at least one flag. `CapStatelessOp` and
`CapStatefulOp` are intended to be mutually exclusive in practice;
the test suite asserts this, but the type does not enforce it,
because a future kind may need to claim both during a transitional
slice.

## Open Questions Deferred Out Of 7.B

These are intentionally left for later slices so the 7.B table can
ship pinned to current code rather than aspirational semantics.

- **`KBusInDelayed` latency.** Its "delay" today is the inter-template
  block-cycle latency the scheduler already handles, not a sample-domain
  latency the planner needs to avoid inlining across. If a later planner
  decision shows it should be `CapLatencyBearing`, the fix is to extend
  `kindLatency` first; the capability table will follow automatically
  through the biconditional test.
- **`KDelay` latency.** Its tap length is a runtime parameter, not a
  kind property, so `kindLatency` returns `Nothing` for it. Same rule
  as above: if it needs to become latency-bearing at the kind level,
  fix `kindLatency` first.
- **Per-plugin refinement of `KStaticPlugin`.** Tracked by §6.E.3.
- **Per-UGen capability narrowing.** A `Gain` with a literal `Param`
  could be more aggressively fused than a `Gain` driven by a
  dynamic signal. The kind-level table cannot express this; per-UGen
  refinement is the planner's job in Phase 7.C.

## Surface

First consumer is `--fusion-survey`. It gains a capability-footprint
section (counts per flag, optionally per `NodeKind`) and capability
annotations on missed-shape rows. No new CLI subcommand.

`--snapshot-check` gains:

- a totality assertion that every `NodeKind` has at least one row;
- stable per-flag counts over the fixed survey corpus.

Per-UGen `inferEff`, per-kind `kindLatency`, `kindSpec`, and `ugenView`
are unchanged.

## Tests Required In The Next Slice

Each test below pins one column of the table to the rest of the
compiler so a future kind addition cannot silently drift.

1. **Totality.** For every `k <- [minBound..maxBound] :: [NodeKind]`,
   `kindCapabilities k` is non-empty.
2. **Stateless/stateful mutual exclusion.** No kind claims both
   `CapStatelessOp` and `CapStatefulOp`.
3. **Latency agreement.** `CapLatencyBearing \`elem\` kindCapabilities k`
   iff `kindLatency k` is `Just _`.
4. **Sink agreement.** `CapSinkTerminal \`elem\` kindCapabilities k`
   iff `k \`elem\` [KOut, KBusOut]`.
5. **Resource agreement.** A fixture map keyed by `NodeKind` provides
   one representative `UGen` per kind; `CapResourceAccess \`elem\`
   kindCapabilities k` iff that representative's `inferEff` contains
   any non-`Pure` effect. The fixture pattern mirrors the existing
   `ugenView`-arity property in `test/Spec.hs`.

## Out Of Scope For Phase 7.B

- A planner decision function. That is Phase 7.C.
- Profitability cost-model rules keyed on capabilities. That is the
  cost-lab consumption pass once measured rows exist.
- Cross-template capability propagation. Template effects already
  flow through `BusFootprint`; the planner consumes both layers, but
  the kind-level table does not need to.
- A new C ABI surface. The capability table is Haskell-only.
- Per-UGen capability narrowing. Kind-level only.
