# Phase 8.D — Routing Helper Contract

Date: 2026-05-12

Status: decision artifact for the 8.D closeout slice. The slice
adds the four routing helpers Phase 8.D promised — `balance`,
`spread`, `send`, `returnBus` — and closes 8.D as the last
routing-shape gap before the ensemble-builder work in 8.E. After
this slice, authoring a multi-template synth + FX patch no
longer requires hand-wiring `busOut` / `busIn` calls.

No runtime, no FFI, no planner, no cost-lab changes. The slice is
purely elaboration: every helper lowers to existing primitives in
`MetaSonic.Bridge.Source` (`gain` / `add` / `busOut` / `busIn` /
`out`). Any graph an 8.D helper emits could be written by hand
node-for-node.

## Scope

Two groups of helpers, all in
[src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs):

1. **Static balance and spread.** These are compile-time
   panning helpers, not dynamic equal-power panners. The
   current primitive set cannot honestly implement
   dynamic equal-power pan (there is no sqrt opcode the
   `KGain` family understands at audio rate, and we are
   not adding one in this slice). 8.D's `balance` /
   `spread` therefore take their pan parameters as
   ordinary `Double`s and lower to plain constant gains
   at graph-build time, not as audio-rate computation.

       balance :: Stereo -> Double -> SynthM Stereo
       spread  :: [Mono] -> Double -> SynthM Stereo

   `balance s p` for `p ∈ [-1, 1]`:
     - `p <= 0` attenuates the right channel by
       `(1 - |p|)` and leaves the left at unity.
     - `p >= 0` attenuates the left channel by `(1 - p)`
       and leaves the right at unity.
     - Emits exactly two `KGain` nodes (one per channel)
       with constant amounts.

   `spread monos width` for `width ∈ [0, 1]`:
     - With `monos = []`, emits zero nodes and returns
       silence on both channels (`Param 0.0` / `Param 0.0`).
     - With `monos = [single]`, emits one centered
       `pan2 single 0.0` — exactly two `KGain` nodes, no
       `KAdd`.
     - With `monos = [m_1, …, m_N]` for `N ≥ 2`, the N
       sources are panned across a `-width .. +width` arc
       using `pan2` and then mixed: emits `2N` `KGain`
       nodes (two per source from `pan2`) and `2(N-1)`
       `KAdd` nodes (mixing left and right separately).
     - The `width` parameter clamps to `[0, 1]`: `width = 1`
       is full spread, `width = 0` is collapsed center, and
       intermediate values scale the per-source pan positions
       linearly.

   Neither helper introduces a new DSP node; the math is
   ordinary `gain` and `add` chains with constants.

2. **Explicit bus authoring surface.**

       newtype Bus = Bus { unBus :: Int }
       bus       :: Int -> Bus
       send      :: Bus -> Mono -> SynthM ()
       returnBus :: Bus -> SynthM Mono

   `Bus` is the only new type. It wraps an `Int` bus
   index — the same value the existing primitive
   `busOut` / `busIn` already accept. `Bus` exists for
   authoring clarity: a `Bus` value is what a `send`
   writes to and a `returnBus` reads from, and the
   bus index is visible at every call site rather than
   threaded through bare `Int`s.

   - `send (Bus n) (Mono c)` lowers to one `KBusOut` on
     bus `n` reading `c`. Same as `busOut n c`.
   - `returnBus (Bus n)` lowers to one `KBusIn` on
     bus `n`. Same as `busIn n` wrapped in `Mono`.
   - `bus n` is a trivial smart constructor; `Bus n`
     also works directly.

   No deterministic allocator. Bus indices stay
   user-managed; allocation is the 8.E ensemble builder's
   job, where template names and roles exist to drive a
   deterministic mapping. 8.D's job is to give 8.E a
   stable primitive to lower into.

## What this slice does not change

- **No dynamic panning.** `pan2` (Phase 8.D's earlier
  slice) already does compile-time equal-power pan; the
  honest path to time-varying equal-power pan needs a
  sqrt opcode or a control-rate sqrt elsewhere. Both are
  out of scope for 8.D.
- **No bus allocator.** No `withBus`, no `freshBus`, no
  reuse-detection. Authors pick bus indices manually,
  same as today.
- **No primitive builder changes.** `busOut` / `busIn` /
  `gain` / `add` stay exactly as they are.
- **No new `NodeKind`.** Every lift uses an existing
  primitive.
- **No new tests outside `authoringDslTests`.** Footprint
  is checked via `compileTemplateGraph` on a paired
  send/return pair, but using the existing
  `ResourceFootprint` and `Template` surface — no new
  inspection types.

## Test discipline

Tests live in `authoringDslTests` in
[test/Spec.hs](test/Spec.hs). They pin **primitive graph
shape** and, for `send` / `returnBus`, the cross-template
`ResourceFootprint` that compilation derives.

Per-helper pins:

- `balance (Stereo l r) p` emits exactly two `KGain`
  nodes; the constant amounts match the policy above for
  both `p ≥ 0` and `p ≤ 0`.
- `balance (Stereo l r) 0` is a structural no-op
  attenuation: both gains are `Param 1.0`.
- `spread [] 1` emits zero `KGain` / `KAdd` nodes.
- `spread [m] 1` emits exactly two `KGain` nodes and no
  `KAdd` (delegates to `pan2`).
- `spread [m_1, m_2, m_3] 1` emits exactly 6 `KGain` and
  4 `KAdd` nodes (2 gains and 1 add per channel per
  source, summed left+right separately).
- `spread monos 0` collapses all sources to center —
  the per-source `pan2` is called with pan `0`, so each
  source gets two `KGain`s of `sqrt 0.5`.
- `send (bus 7) (Mono c)` emits exactly one `KBusOut`.
- `returnBus (bus 7)` emits exactly one `KBusIn` and
  returns a `Mono` wrapping the resulting `Connection`.
- An end-to-end `send` → `returnBus` paired demo
  compiles through `compileTemplateGraph` and produces:
    - `tplFootprint` for the send-side template has
      `bfWrites = {7}` and `bfLiveReads = ∅`;
    - `tplFootprint` for the return-side template has
      `bfWrites = {0}` (the hardware `Out 0`) and
      `bfLiveReads = {7}`;
    - `tgTemplates` orders the send template before the
      return template (the `compileTemplateGraph`
      precedence contract).

The footprint test is the one that matters most: it
proves the lifted `send` / `returnBus` lower to
something `compileTemplateGraph` recognizes structurally
in exactly the same way the hand-written
`busOut` / `busIn` already do.

## Demo

The existing `send-return` demo's voice and fx graphs are
rewritten to use `Auth.send` and `Auth.returnBus`. The
compiled `RuntimeGraph` / `TemplateGraph` shape stays
byte-identical: same node count, same bus footprint, same
template ordering. The rewrite is the clearest proof that
8.D reduces boilerplate without hiding buses — the lowered
graph still inspects as ordinary `KBusOut` / `KBusIn` /
`KOut` nodes, and `--fusion-survey send-return` reads the
same template fingerprints as before.

## Verification

- `stack test --test-arguments='--hide-successes'`
- `stack exec -- metasonic-bridge --snapshot-check`
  (regression check: no snapshot pin should move; the
  authoring layer is below the cost-lab/gate machinery).
- `stack exec -- metasonic-bridge --fusion-survey send-return`
  to confirm the rewritten demo still produces the
  documented bus footprint.

No C++ test run needed — the slice does not cross the FFI
boundary.

## What this enables (and what it doesn't)

After 8.D, a multi-template synth + FX patch can be
authored without dropping into primitive `busOut`/`busIn`:

    voice = runSynth $ do
      pitch     <- ...
      carrier   <- sawOsc pitch 0.0
      amped     <- gain carrier 0.4
      Auth.send (Auth.bus 7) (Auth.mono amped)

    fx = runSynth $ do
      sent     <- Auth.returnBus (Auth.bus 7)
      filtered <- Auth.lpfM sent (Param 800.0) (Param 0.7)
      Auth.outMono 0 filtered

What 8.D still does **not** give the author:

- A bus allocator. Authors still pick `7` by hand. 8.E
  will turn this into named send-bus roles whose indices
  the compiler picks.
- Named controls. `pitch` / `gate` / `cutoff` etc. still
  come in as bare `Connection` / `Param` values. 8.F.
- Cross-template safety (e.g., "this bus is written but
  never read"). The compile-side `compileTemplateGraph`
  already surfaces some of this in `tplFootprint`, but
  the authoring layer does not yet gate on it.

## Outcome ladder

  1. All four helpers land, tests pin lowered shape and
     bus footprint, the rewritten demo round-trips
     byte-identically. **Mark 8.D complete; point 8.E at
     deterministic bus allocation and template naming.**
  2. `balance` / `spread` land but `send` / `returnBus`
     hit a structural problem (e.g., compileTemplateGraph
     requires more metadata than the existing
     `busOut`/`busIn` already provide). **Keep 8.D
     partial; investigate the metadata gap.**
  3. The send/return rewrite changes the compiled graph
     shape (different node counts, different footprint).
     **Stop the slice.** The promised "lower to normal
     `BusOut`/`BusIn`" contract has not been kept and the
     helpers need to be reshaped, not landed.

Case 1 is the target; if the byte-identical compile
round-trips, the slice is the closeout.

## Related artifacts

- [notes/2026-05-12-h-phase-8c2-lifted-stateful-ugens.md](notes/2026-05-12-h-phase-8c2-lifted-stateful-ugens.md)
  — 8.C2 closeout; same elaboration-only contract.
- [notes/2026-05-11-l-phase-8-authoring-dsl-design.md](notes/2026-05-11-l-phase-8-authoring-dsl-design.md)
  — overall Phase 8 design.
- [src/MetaSonic/Bridge/Templates.hs](src/MetaSonic/Bridge/Templates.hs)
  — `BusFootprint` / `ResourceFootprint` / `Template`
  types the footprint test consumes. Unchanged.
- [app/MetaSonic/App/Demos.hs](app/MetaSonic/App/Demos.hs)
  — where the `send-return` demo lives; rewritten by
  this slice.
