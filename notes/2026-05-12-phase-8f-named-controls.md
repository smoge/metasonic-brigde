# Phase 8.F — Named Controls v1

Date: 2026-05-12

Status: decision artifact for the 8.F closeout slice. The
slice adds the named-control layer 8.E parked: an authoring
helper that lowers a name + default + range into a tagged
smoother node, optionally records a MIDI CC binding against
the same node, and reuses the OSC dispatcher's existing
`/<voice>/<node-tag>/<slot>` grammar verbatim. After this
slice, authoring `cutoff` / `freq` / `vol` no longer requires
hand-pairing a `smooth` call with `tagged` and a separate
`CCMapping`.

No runtime, FFI, planner, or dispatcher changes. The slice
is elaboration plus a narrow Source-layer helper. Every
named-control node is an ordinary `KSmooth` after lowering;
the dispatcher resolves its OSC address through the same
`MigrationKey` lookup it already runs for any tagged node.

## Scope

Two sites:

1. [src/MetaSonic/Bridge/Source.hs](src/MetaSonic/Bridge/Source.hs)
   gets one new function, `recordCCBinding :: CCSpec -> SynthM ()`.
   The existing `cc` is rewritten to call it; behavior is
   unchanged. Exposing the helper lets the authoring layer
   record bindings without duplicating Source state plumbing.

2. [src/MetaSonic/Authoring.hs](src/MetaSonic/Authoring.hs)
   gets the named-control authoring API.

### Types

    newtype ControlName = ControlName String

    data ControlRange = ControlRange
      { crMin :: Double
      , crMax :: Double
      }

    data ControlOptions = ControlOptions
      { coSmoothingHz :: Double
        -- default 20.0, matching `cc`
      }

    data NamedControl = NamedControl
      { ncMono     :: Mono
      , ncMetadata :: NamedControlMetadata
      }

    data NamedControlMetadata = NamedControlMetadata
      { ncmName        :: !String
      , ncmDefault     :: !Double
      , ncmRange       :: !ControlRange
      , ncmSmoothingHz :: !Double
      , ncmCC          :: !(Maybe Word8)
      , ncmKey         :: !MigrationKey
      , ncmSlot        :: !Int
        -- pinned to 1: the smoother's target slot
      }

`NamedControl` is the authoring-time handle. Its `Mono`
field is the same shape every other authoring node returns,
so the rest of the lifted surface composes against it
without any new combinators.

### Smart constructors

    controlName  :: String -> Either String ControlName
    controlRange :: Double -> Double -> Either String ControlRange

`controlName` validates against the same identifier profile
the OSC dispatcher already enforces: non-empty, no slash, no
space, no NUL, and at most 16 UTF-8 bytes. Rejected on the
authoring side rather than at compile or dispatch time.

`controlRange` rejects `crMin >= crMax`. Range is metadata
plus MIDI scaling input; it is not enforced at OSC runtime
(see "What this slice does not change" below).

### Builder API

    control       :: ControlName -> Double -> ControlRange
                  -> SynthM NamedControl
    controlWith   :: ControlOptions -> ControlName -> Double
                  -> ControlRange -> SynthM NamedControl

    ccControl     :: Word8 -> ControlName -> Double -> ControlRange
                  -> SynthM NamedControl
    ccControlWith :: ControlOptions -> Word8 -> ControlName
                  -> Double -> ControlRange -> SynthM NamedControl

    controlMono       :: NamedControl -> Mono
    controlConnection :: NamedControl -> Connection

`controlWith` is the primitive: it emits

    tagged name (smooth coSmoothingHz (Param default))

and records the metadata. `control` is
`controlWith defaultControlOptions`.

`ccControlWith` emits the same tagged smoother, then calls
`recordCCBinding` with a `CCSpec` pointing at the smoother's
target slot (`ctl = 1`) and the supplied range. `ccControl`
is `ccControlWith defaultControlOptions`.

`controlMono` / `controlConnection` are projection
conveniences — `ncMono` and the `Mono`'s underlying
`Connection`.

### Defaults

    defaultControlOptions :: ControlOptions
    defaultControlOptions = ControlOptions { coSmoothingHz = 20.0 }

20 Hz matches the existing `cc` smoother. Pinned by tests so
silent drift would fail the suite.

## What this slice does not change

- **No new `NodeKind`.** Named controls lower to the
  existing `KSmooth`. The target slot is `control[1]`, the
  same slot `cc` already targets.
- **No FFI changes.** The C++ runtime never sees authoring
  names. It only sees the lowered `KSmooth` with its
  migration key bytes, which it already handles.
- **No dispatcher grammar change.** OSC resolution still
  goes through `/<voice>/<node-tag>/<slot>`; the `node-tag`
  is the `MigrationKey` stored on the smoother node, and
  `slot = 1`. Arbitrary `oscControl "/custom/path"`
  authoring stays parked until session/control routing has
  a real ownership contract — exposing it now would freeze
  an interface before the contract exists.
- **No runtime clamping.** OSC `min`/`max` are metadata
  (for inspector/UI) and MIDI CC scaling input only. An OSC
  write outside the declared range still lands on the
  control slot exactly as the dispatcher resolves it. The
  smoother does not clip.
- **No hot-swap or migration state changes.** A named
  control's `MigrationKey` is the control's name verbatim;
  state migration uses the same key bytes it already does
  for any tagged smoother.
- **No `runSynthCCs` shape change.** `ccControl` records
  through the same `CCSpec` list `cc` writes to. The
  live-MIDI runner sees no difference.

## Test discipline

Tests live in `authoringDslTests` in
[test/Spec.hs](test/Spec.hs) and pin the elaboration
contract, not authoring-side ergonomics:

- `controlName` accepts `"cutoff"`, `"vol"`, `"a_b-c"`;
  rejects `""`, `"with space"`, `"with/slash"`, and a
  17-byte name.
- `controlRange 0 1` succeeds; `controlRange 1 0` and
  `controlRange 0.5 0.5` reject.
- `defaultControlOptions` has `coSmoothingHz = 20.0`.
- `control name default range` emits exactly one `KSmooth`
  with the smoother's target initialized to `default`.
- The smoother carries `MigrationKey name` and `ncmSlot = 1`.
- `ccControl cc name default range` emits the same one
  `KSmooth` and records exactly one `CCSpec` with
  `ccsNumber = cc`, `ccsCtl = 1`, `ccsMin = crMin range`,
  `ccsMax = crMax range`, and `ccsNode` pointing at the
  smoother.
- `ccControlWith` preserves a non-default `coSmoothingHz`
  on the emitted `KSmooth`.
- Compile + OSC round-trip: a graph built from one named
  control compiles through the existing template pipeline,
  and `dispatch` on `/<voice>/<name>/1` resolves to the
  smoother's dense `NodeIndex` (slot `1`).
- `NamedControlMetadata` is authoring-side only — a graph
  that ignores metadata and uses only `controlMono` /
  `controlConnection` compiles identically to one that
  doesn't carry the helper at all.

## What this enables (and what it doesn't)

After 8.F, a voice template's `cutoff` and `vol` become
declarative one-liners:

    runSynth $ do
      Right cutoffName <- pure (controlName "cutoff")
      Right cutoffRng  <- pure (controlRange 200 8000)
      cutoff <- control cutoffName 1200 cutoffRng

      Right volName <- pure (controlName "vol")
      Right volRng  <- pure (controlRange 0 1)
      vol <- ccControl 7 volName 0.3 volRng

      osc    <- sinOsc 220 0
      filt   <- lpf osc (controlConnection cutoff) 0.7
      master <- gain filt (controlConnection vol)
      out 0 master

The lowered graph is identical to today's hand-wired
`tagged "cutoff" (smooth 20 (Param 1200))` + `tagged "vol"
(smooth 20 (Param 0.3))` + a manually maintained `CCSpec`
for vol — same node count, same edges, same effects, same
migration keys.

What 8.F still does **not** give the author:

- Per-control session ownership. OSC and MIDI both target
  the same smoother slot; arbitration between them is the
  dispatcher's job, not the authoring layer's.
- Custom OSC addresses. The dispatcher only resolves
  `/<voice>/<node-tag>/<slot>`. Allowing arbitrary paths
  needs a routing contract and is explicitly out of scope.
- Inspector / TUI surfacing of named-control metadata.
  `NamedControlMetadata` exists for 8.G to consume.
- Validation that every authored control is reachable from
  some output. The standard graph reachability pass already
  catches isolated nodes; named controls are not special.

## Outcome ladder

  1. Named controls land, the smoother carries the
     migration key, MIDI binding records through the same
     `CCSpec` list, and OSC dispatch round-trips through
     the existing dispatcher. **Mark 8.F complete.** Point
     8.G at inspector/survey surfacing.
  2. Named controls land but require a new OSC grammar or
     a new FFI entry. **Stop the slice.** The "lower to
     existing dispatcher input" contract is broken.
  3. Named controls land but the dispatcher round-trip
     test does not pass with the same address shape MIDI
     would use. **Mark 8.F partial.** The point of the
     layer is exactly the address reuse.

Case 1 is the target.

## Related artifacts

- [notes/2026-05-12-phase-8e-ensemble-builder.md](notes/2026-05-12-phase-8e-ensemble-builder.md)
  — 8.E closeout; the ensemble builder named controls
  attach metadata to in 8.G.
- [notes/2026-05-11-phase-8-authoring-dsl-design.md](notes/2026-05-11-phase-8-authoring-dsl-design.md)
  — overall Phase 8 design.
- [src/MetaSonic/Bridge/Source.hs](src/MetaSonic/Bridge/Source.hs)
  — `cc`, `tagged`, `MigrationKey`, `CCSpec`, and the new
  `recordCCBinding` helper.
- [src/MetaSonic/OSC/Dispatch/Internal.hs](src/MetaSonic/OSC/Dispatch/Internal.hs)
  — `dispatch` reads the same migration key bytes named
  controls write.
