# Phase 8.C2 — Lifted Stateful/Common UGens

Date: 2026-05-12

Status: decision artifact for the 8.C2 slice. The slice closes
out the common authoring surface 8.C promised: high-/band-/notch
biquads, delay lines, control smoothing, and envelope
*application* (not just an `env` re-export). After this slice,
the authoring layer covers every musically-common shape an
ordinary patch needs without dropping into primitive
`MetaSonic.Bridge.Source` builders, and the lowering tests
pin the primitive graph shape for each helper.

No runtime changes. No FFI changes. No new `NodeKind`. No new
planner verdicts, cost-lab variants, or recognizer extensions.
The slice is purely elaboration: every helper here lowers to
the existing `hpf` / `bpf` / `notch` / `delayL` / `smooth` /
`env` / `gain` primitives in `MetaSonic.Bridge.Source`. Any
graph an 8.C2 helper emits could have been written by hand
node-for-node.

## Scope

Three groups of helpers, all in
[src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs):

1. **Biquad family completion.** Mirror the existing
   `lpfM / lpfS / lpfC` lifts for the other three biquads:

       hpfM, hpfS, hpfC
       bpfM, bpfS, bpfC
       notchM, notchS, notchC

   Every helper takes `(sig, freq, q)` and lowers per channel
   to one `KHPF` / `KBPF` / `KNotch` node. No filter sharing
   across channels — stereo HPF emits two independent
   filters, exactly like `lpfS` already does.

2. **Delay and smooth.**

       delayM :: Double -> Mono     -> Connection -> SynthM Mono
       delayS :: Double -> Stereo   -> Connection -> SynthM Stereo
       delayC :: Double -> Channels -> Connection -> SynthM Channels

       smoothM :: Double -> Mono     -> SynthM Mono
       smoothS :: Double -> Stereo   -> SynthM Stereo
       smoothC :: Double -> Channels -> SynthM Channels

   Per-channel state is preserved by emitting one `KDelay`
   per stereo / channels slot (each carries its own ring
   buffer at the runtime), and one `KSmooth` per slot. Sharing
   delay state across channels would silently flatten the
   stereo image; the lowering must look just like a hand-
   authored multi-channel patch.

3. **Envelope *application*.** Not raw `env` wrappers:

       envM :: Mono     -> Connection -> Connection -> Connection -> Connection -> Connection -> SynthM Mono
       envS :: Stereo   -> Connection -> Connection -> Connection -> Connection -> Connection -> SynthM Stereo
       envC :: Channels -> Connection -> Connection -> Connection -> Connection -> Connection -> SynthM Channels

   Each takes `(sig, gate, attack, decay, sustain, release)`
   and emits **one shared** `KEnv` node plus N `KGain` nodes
   (one per channel). The shared-env semantics are the whole
   point: stereo and channel-wise envelope application should
   produce a single coherent amplitude trajectory across all
   channels, not N independent envelopes that drift if their
   gate inputs ever differ.

   If a caller wants per-channel envelope state, they call
   `envM` independently per channel — the multichannel helpers
   never silently fan out the envelope.

   Empty `Channels` policy: `envC (Channels [])` emits **zero**
   nodes. No dead `Env` node. The semantics of "apply an
   envelope to nothing" is "nothing happens." This matches the
   existing `mapChannels` / `gainC` / `lpfC` behavior on
   empty input.

## What this slice does not change

- No new `NodeKind`. Every lift uses an existing primitive.
- No primitive builder changes. `hpf` / `bpf` / `notch` /
  `delayL` / `smooth` / `env` in `MetaSonic.Bridge.Source`
  stay exactly as they are.
- No bus allocation. `send` / `returnBus` are explicitly
  Phase 8.D and remain out of scope here.
- No named controls or ensemble builders. Those are
  Phase 8.F / 8.E.
- No new demos beyond one small showcase patch. The point is
  not to demo every new helper; it is to show that the
  combined lifted surface removes boilerplate while the
  lowered graph stays inspectable.

## Test discipline

The slice's tests live in `authoringDslTests` in
[test/Spec.hs](test/Spec.hs) and follow the existing pattern:
they pin **primitive graph shape**, not arity in the
authoring API. Examples:

- `hpfS` emits exactly two `KHPF` nodes (one per channel);
- `bpfS` emits exactly two `KBPF` nodes;
- `notchS` emits exactly two `KNotch` nodes;
- `delayS` emits exactly two `KDelay` nodes, both carrying
  the same compile-time `maxDelay`;
- `smoothC chCount` emits exactly `chCount` `KSmooth` nodes;
- `envS` emits exactly one `KEnv` plus two `KGain` nodes —
  the shared-env contract is what the count pin protects;
- `envC chCount` emits exactly one `KEnv` plus `chCount`
  `KGain` nodes;
- `envC (channels [])` emits **zero** `KEnv` / `KGain`
  nodes (no dead env).

The shared-env tests also pin that the gate connection is
identical across the per-channel `Gain` inputs — the test
asserts both gain nodes consume the same `KEnv` node index.
That's the only way to keep `envS` from being silently
reshaped into two independent envelopes by a future
refactor.

## Demo

One small authored demo extension: a stereo patch using the
new helpers end-to-end —

    stereoSrc → hpfS → envS → delayS → gainS → stereoOut

This replaces the existing `stereo-saw` demo's wording (or
adds a sibling demo, depending on what fits the demoTable
layout) and is added to the demo table so the lowering can
be inspected with `--inspect-only`. The point is showing
that 8.C2 makes a multi-effect stereo chain look like the
intent on the page, while the lowered primitive graph still
inspects as ordinary `KHPF` / `KEnv` / `KGain` / `KDelay` /
`KOut` nodes.

## Verification

- `stack test --test-arguments='--hide-successes'`
- `stack exec -- metasonic-bridge --snapshot-check`
  (regression check: no snapshot pin moves; the authoring
  layer is below the cost-lab/gate machinery)
- `stack exec -- metasonic-bridge --inspect-only <new-demo>`
  to confirm the demo's lowered graph reads as primitive

No C++ test run needed — the slice does not cross the FFI
boundary.

## Related artifacts

- [notes/2026-05-11-l-phase-8-authoring-dsl-design.md](notes/2026-05-11-l-phase-8-authoring-dsl-design.md)
  — overall Phase 8 contract: elaboration only, primitive
  graph stays inspectable, no second compiler.
- [src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs)
  — where the helpers land. Existing `lpfM` / `gainS` /
  `mapChannels` machinery defines the patterns this slice
  follows.
- [src/MetaSonic/Bridge/Source.hs](src/MetaSonic/Bridge/Source.hs)
  — primitive builders the lifted helpers wrap. Unchanged.

## What this enables (and what it doesn't)

After 8.C2, an authored stereo patch with the standard
musical chain — filter, envelope, delay, master gain,
output — can be written without dropping into mono primitives:

    g = runSynth $ do
      src    <- ...
      filtSt <- Auth.hpfS src 1200.0 0.7
      envSt  <- Auth.envS  filtSt gate 0.01 0.2 0.8 0.5
      delSt  <- Auth.delayS 0.3 envSt 0.15
      outSt  <- Auth.gainS delSt 0.25
      Auth.stereoOut 0 outSt

What 8.C2 still does **not** give the author:
- Named controls. `gate` / `attack` etc. still come in as
  bare `Connection` / `Param` values.
- Send/return bus authoring. The patch still wires through
  `Connection` values directly; cross-template routing
  remains primitive-side.
- Ensemble / voice templates. The patch is one `SynthGraph`.

Those are the 8.D / 8.E / 8.F surfaces and remain their own
slices.
