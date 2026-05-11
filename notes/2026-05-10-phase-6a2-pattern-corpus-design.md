# Phase 6.A.2 — Pattern Contract and Corpus Design

Date: 2026-05-10
Status: design only; fixes the `Pattern` type contract and the list
of corpus rows before any module / test code lands.

## Position in the roadmap

6.A.2 is the implementation step that follows the 6.A.1 bounds note
([Phase 6.A pattern design](2026-05-10-phase-6a-pattern-design.md)).
This companion note settles two things 6.A.1 explicitly punted to
6.A.2:

- The `Pattern` *contract* — what a pattern is, what it produces,
  what determinism guarantees it carries.
- The *corpus list* — the original five named rows, each defensible
  as music rather than as a gate probe. Later phases may add rows
  when new compiler/runtime surface needs real corpus signal; those
  additions should preserve the same standard rather than mutate the
  original evidence.

The actual module API (constructors, combinators, helpers) is
implementation territory, not contract territory. This note fixes
*what a pattern must be*, not *what convenient functions exist to
build one*.

## Pattern contract

### Time model

Patterns advance in **pattern-time**, expressed as discrete sample
positions relative to the pattern's own zero. Not wall-clock seconds,
not floating-point time, not block-relative offsets.

This guarantees determinism: a pattern's event stream over the
half-open sample range `[t0, t1)` is a pure function of `(pattern,
t0, t1)`. Sub-block precision is permitted in the contract (events
carry a `SamplePos`, not just a block index) but the v1 runtime
delivers events at block boundaries; sub-block timing is decoration
that the verification gate ignores. Sample-accurate event delivery
is explicitly out of 6.A; it sits in the same parked queue as
"sample-accurate connected control inputs" from Phase 0.

### Event categories

A pattern emits **symbolic** events. The pattern itself never names
runtime instance slots, swap generations, or any other identifier the
audio thread assigns. A separate *driver* layer (specified below)
translates symbolic events into the realtime ABI surface
(`rt_graph_realtime_reserve` / `_activate` / `_release` / `_remove` /
`_set_control` — see [tinysynth/rt_graph.h](../tinysynth/rt_graph.h))
and the §5.3 swap helpers.

```
data PatternEvent
  = PEVoiceOn      !TemplateName !VoiceKey ![(ControlTag, Value)]
  | PEVoiceOff     !VoiceKey
  | PEControlWrite !VoiceKey !ControlTag !Value
  | PEHotSwap      !SwapLabel !TemplateGraph
```

- `PEVoiceOn` triggers a voice of the named template, identifies it
  with a pattern-local `VoiceKey`, and supplies its initial control
  values. The driver implements this as the §2.E
  reserve → set_control (while Reserved) → activate sequence and
  records `VoiceKey -> slot_id` in its own table.
- `PEVoiceOff` releases the same logical voice. The driver looks up
  the slot and calls `rt_graph_realtime_release`. Slot reuse follows
  §2.E release-then-free; the pattern does not see `Remove`.
- `PEControlWrite` updates a control on a live voice. The driver
  resolves `(VoiceKey, ControlTag)` to a `(slot_id, node_index,
  control_slot)` triple and calls
  `rt_graph_realtime_set_control`.
- `PEHotSwap` carries a pre-compiled ensemble the producer wants
  installed. The driver reads the current generation, calls the
  appropriate §5.3 helper (`hotSwapTemplateGraph` /
  `hotSwapTemplateGraphAndWait`), waits for install, and collects
  the retired swap.

#### Symbolic identifiers

- `TemplateName` — symbolic name that resolves against the
  pattern's closed initial template set. Same shape as the existing
  `tplName`.
- `VoiceKey` — pattern-local stable identity. Two events sharing a
  `VoiceKey` refer to the same logical voice across `PEVoiceOn`,
  `PEVoiceOff`, and `PEControlWrite`. The driver assigns runtime
  slot identity; the pattern only emits keys.
- `ControlTag` — `(NodeTag, ControlSlot)` pair where `NodeTag` is
  the same migration-key shape §5.2 already uses for state
  migration and §5.4.B uses for template identity. Reusing that
  16-byte-token shape across §5 and 6.A means a producer that
  already marks nodes for state migration gets pattern-level
  control targeting for free.
- `SwapLabel` — producer-readable label that names a swap event
  for audit / `--swap-bench` reporting; not load-bearing for ABI
  resolution.

Patterns emit no `InstanceId`, no `SwapGeneration`, no `NodeIndex`,
no slot IDs, no `control_slot` integers without a `NodeTag`
qualifier. Those are driver-side resolution outputs, not pattern-side
inputs.

6.A.2 adds no new realtime ABI surface, no new event kinds beyond
the four above, and no audio-thread substrate.

### Driver responsibilities

The driver is *not* shipped in 6.A.2. The contract names what it
must do so the pattern type can be designed against a real
consumer:

1. **Compile / load the pattern's initial templates** at pattern
   start. The pattern carries a `TemplateGraph` (already compiled by
   the pattern author), so the driver only loads — no compile path
   on the realtime side.
2. **Maintain a `VoiceKey -> slot_id` table.** On `PEVoiceOn`,
   reserve a slot via `rt_graph_realtime_reserve`, set initial
   controls while Reserved, activate, and record the mapping. On
   `PEVoiceOff`, look up the slot and release. Mapping cleanup
   follows §2.E release-then-free; the table can carry a small
   tombstone window so stale `PEControlWrite` events on a just-
   released voice are silently dropped, not misrouted.
3. **Maintain a `(template_id, NodeTag) -> NodeIndex` resolution
   table** per generation. `ControlTag` carries a `NodeTag` (the
   §5.2 migration-key shape); the driver looks it up in the
   currently-installed `TemplateGraph`'s tag table. After a swap,
   the driver re-resolves the table against the new generation
   because node indices may differ even when migration-keys match.
4. **Publish swaps and reap stats.** On `PEHotSwap`, read current
   generation, call the §5.3 `hotSwapTemplateGraphAndWait` helper,
   collect retired stats, and re-resolve the tag table for the new
   generation before the next event fires.
5. **Obey the single-producer realtime queue contract.** The
   driver is a single thread (or single sequencer) feeding the
   realtime queues; concurrent producers feeding the same queues is
   out of v1 scope (mirrors §5.3's documented single-producer /
   single-collector limitation).

### Pattern as a function

```
data Pattern = Pattern
  { patternTemplates :: TemplateGraph
  , patternEvents    :: SampleRange -> [(SamplePos, PatternEvent)]
  }
```

`patternTemplates` is the **pre-compiled** initial ensemble the
driver loads at pattern start. Compile errors surface at pattern
construction time, never on the realtime path. Swap targets are
embedded inline in `PEHotSwap` events — each event carries its own
already-compiled `TemplateGraph` — so the closed-set property
extends across the pattern's full lifetime: every template the
pattern ever references is compiled before any audio thread sees
it.

`patternEvents` is a deterministic pure function: given a sample
range, return the events that fall inside it, in non-decreasing
`SamplePos` order. No `IO`, no mutable state, no implicit
randomness. Patterns that need randomness take an explicit seed
(passed through the constructor that built the `Pattern`).

This shape — pure function, closed template set across the
pattern's full lifetime, deterministic ordering — is what makes
the 6.A.3 verification gate possible.

### Determinism rule

For any pattern `p` and any sample range `r`:

```
patternEvents p r === patternEvents p r
```

byte-identical across runs, across processes, across machines. No
wall-clock dependency, no thread-scheduling dependency, no FFI side
effects.

This is the property that makes the corpus a regression target
rather than a smoke test. If a row's expansion drifts, that drift is
either a real change to the pattern (which the regression pin
catches) or a defect in the expansion implementation (also caught).

### Patterns are producers, not schedulers

A clock thread that walks pattern-time forward and delivers events
to the audio thread is *out of scope for 6.A.2*. The pattern type
makes the events available; a separate driver decides when to fetch
them. The 6.A.3 verification gate exercises `patternEvents`
directly, not through a clock thread.

When a clock-driven driver eventually lands, it is a layer above the
pattern type, not inside it. The pattern type stays a pure
function.

## Corpus rows

Five rows. Each is defensible as a real musical idea independent of
which §4 / §5 gates it incidentally exercises. Per 6.A.1's corpus
naturalness rule: rows are chosen because they are music; coverage
of survey / bench signals is incidental.

### Row 1 — `drone-with-vibrato`

A single voice template: sine carrier with vibrato (slow sine LFO on
the carrier's frequency input), fed through a low-pass filter and a
scalar output gain to a hardware bus. The pattern emits one
`PEVoiceOn` at t=0 (with initial values for carrier base frequency,
vibrato depth, LPF cutoff, and output gain), a periodic
`PEControlWrite` stream sweeping the LPF cutoff control over the
duration, and one `PEVoiceOff` near the end.

*Why it's music.* A held drone with slow filter movement is the
simplest non-trivial musical gesture; it tests a single sustained
voice with continuous parameter motion.

*Expected survey/bench signal (verify in 6.A.3).* Single-template
ensemble; one Active slot for the pattern's duration; `--swap-bench`
unchanged-graph baseline (the pattern issues no swaps). The
`SinOsc → LPF → Gain → Out` tail is not claimed by the current §4.B
kernel set (no `RSinLpfGainOut` exists); the row therefore
incidentally documents a parked Sin-rooted filtered tail in the
`--fusion-survey` missed-shape table. Whether that row crosses the
§4.B.x recurrence gate (`missed ≥ 3 ∧ sources ≥ 3`) is a 6.A.3
question, not a 6.A.2 claim.

### Row 2 — `arpeggio-send-return`

A voice template (saw → envelope-shaped gain → `BusOut 5`) plus an
FX template (`BusIn 5 → LPF → scalar Gain → Out 0`). The pattern
emits `PEVoiceOn` / `PEVoiceOff` events for a fixed pitch cycle at
fixed beat intervals; the fx template runs as a single long-lived
instance.

*Why it's music.* An arpeggio through a shared FX bus is a textbook
subtractive-synth pattern; arpeggiator + filter is recognizable as
music to anyone who has heard a synthesizer.

*Expected survey/bench signal (verify in 6.A.3).* The fx template's
tail (`BusIn → LPF → scalar Gain → Out`) is a structural candidate
for `RBusInLpfGainOut`, conditional on the Gain staying scalar — and
in this row it does, since the pattern's control writes target
`lpf.freq` and `gain.amount` rather than audio-rate inputs. The
voice template's `Saw → Env-modulated Gain → BusOut` chain has an
audio-modulated Gain (envelope feeds the gain input), so per §4.B
that chain does *not* fall into any sink-terminal kernel and stays
on per-node dispatch. Multi-template inter-template precedence
(voice before fx, derived from `BusFootprint`) is exercised; voice
events stress §3 lifecycle plus §2.E release-then-free.

### Row 3 — `polyphonic-stab`

A single voice template: white noise through a low-pass filter, the
filter output shaped by an envelope-modulated gain to a hardware
output. Eight voices fire simultaneously at one pattern-time
position (eight `PEVoiceOn` events at the same `SamplePos` with
distinct `VoiceKey`s), and release together a few hundred
milliseconds later (eight `PEVoiceOff` events). Each voice gates
its own envelope on `PEVoiceOn`.

*Why it's music.* A polyphonic noise stab is a percussion / impact
gesture; simultaneous voice triggering is how chord stabs and drum
hits work.

*Expected survey/bench signal (verify in 6.A.3).* This row is
deliberately *not* a clean kernel hit. The structural shape is
`NoiseGen → LPF → Gain → Out` with the Gain audio-modulated by an
Env output. §4.B's `RNoiseLpfGainOut` requires the Gain to be
scalar, so audio-modulated Gain blocks the kernel and the chain
falls back to per-node dispatch. The row therefore documents a
defensible musical shape the current kernel set misses — useful
§4.B.x evidence if the missed-shape table grows a
`NoiseLpfEnvGainOut`-style row past the recurrence threshold over
time. Eight simultaneous voices give `--worker-bench` a wide
Free-band candidate at the §4.E worker partition; the Out per
voice keeps it sink-bearing, not sink-free, so it routes through
the C1d serial-or-reduce path rather than the synthetic
`RegionItems` sink-free band. §2.E release-then-free is exercised
across eight instances in one batch.

### Row 4 — `hot-swap-edit`

A held single-template drone (`SinOsc → LPF → Out`, simpler than
row 1's vibrato chain) plays continuously under one long-lived
voice (one `PEVoiceOn` at t=0, one `PEVoiceOff` near the end).
Midway through the pattern's duration, a single `PEHotSwap` event
carries a recompiled `TemplateGraph` whose LPF cutoff baseline
differs. The same template name and identity token carry across the
swap.

*Why it's music.* Live re-patching during a held sound is the
defining workflow that motivated Phase 5 in the first place.

*Expected survey/bench signal (verify in 6.A.3).* `--swap-bench`
measures producer cost across one pattern-driven swap rather than
the fixed single-shot battery; §5.4.B identity precondition is
expected to succeed on the matched-token swap (verifiable by
inspecting `blocks_to_install` and the install-success counter);
§5.2 migration counters report which DSP state was copy-safe vs.
default-init across the swap. Per the §5 status note's remaining-gap
acknowledgement, oscillator phase is *expected* to migrate, while
Env / Delay / Smooth default-init across the swap; this row's
sine carrier exercises the safe path explicitly.

### Row 5 — `layered-ensemble`

Two distinct voice templates — `bass` (saw → LPF → envelope-shaped
gain → `BusOut 5`) and `pad` (paired detuned sines → envelope-shaped
gain → `BusOut 5`) — running concurrently. The v1 corpus row plays
them lightly: `pad` sustains one long voice for the pattern's full
duration, `bass` plays two sequential notes (no overlap within the
bass family; bass and pad overlap for the first half of the
pattern). Both route through a shared FX template
(`BusIn 5 → LPF → scalar Gain → Out 0`) which runs as one long-lived
voice. A "3 voices per family" version is straightforward to lift
later once the verification gate has more polish.

*Why it's music.* Bass + pad through a shared bus is the smallest
arrangement that sounds like a piece rather than a test signal.

*Expected survey/bench signal (verify in 6.A.3).* Multi-template
inter-template precedence (bass and pad both write to bus 5; fx
must follow both, derived from `BusFootprint`). The fx tail is
again a structural `RBusInLpfGainOut` candidate under the same
scalar-Gain caveat as row 2. The voice families have audio-modulated
Gain (envelope-shaped), so they stay on per-node dispatch. Shared-bus
contention metadata appears in `--fusion-survey`'s parallel-readiness
section; whether the rows cross the existing C1c / C1d-c thresholds
in `--worker-bench` is the gate signal 6.A.3 reports.

## Verification gate preview (for 6.A.3)

This note does not implement 6.A.3, but it fixes the assertions
6.A.3 must make so the corpus contract is testable:

1. **Deterministic expansion regression.** For each row, the
   expanded event list over a fixed sample range (e.g. 4 seconds
   at 48 kHz) is pinned byte-identical. The expected value is an
   inline Haskell list adjacent to the pattern definition; no
   on-disk golden files. Same shape as test/Spec.hs's existing
   structural pins.
2. **Corpus-shape regression.** For each row, the *compiled
   RuntimeGraph* shape (region kernels claimed, fused inputs
   registered, BusFootprint extents) is pinned. This is the gate
   that catches accidental drift between the pattern's
   `SynthGraph` and what the bridge compiles it into.
3. **Survey / bench recognition (layer (b) from 6.A.1).** Running
   `--fusion-survey`, `--worker-bench`, and `--swap-bench` against
   the corpus reports whether parked rows in the §4 / §5 ranked
   tables move. The result is a single text report; movement is
   evidence, not a pass/fail.

(1) and (2) are unit-style regression pins. (3) is a descriptive
report that turns the corpus into Phase 4 / Phase 5 signal.

## Out of 6.A.2 scope

This note does not specify:

- **Pattern combinators / ergonomic API.** `(<>)`, `shift`,
  `loop`, `stretch`, beat-grammar sugar — all of those are 6.A
  post-verification work, after 6.A.3 confirms the contract is
  honest.
- **Clock-driven driver.** Wall-clock-paced event delivery is a
  layer above this type; it is not part of the contract.
- **Sub-block timing.** Events may carry a `SamplePos` but the v1
  runtime delivers at block boundaries.
- **Live-MIDI integration.** MIDI input is already a producer via
  §3; cross-traffic between MIDI and Pattern is 6.A surface that
  6.A.2 does not need to settle.
- **Pattern persistence.** Serialization or hashing of `Pattern`
  values across processes / disk is not in scope. Corpus rows are
  Haskell values; their regression-pin expected event lists are
  also inline Haskell values next to those rows. Test fixtures are
  *not* persistence — they are source artifacts.

## Implementation outline (for the next step)

When 6.A.2 implementation lands, the minimum surface is:

- `src/MetaSonic/Pattern.hs` — `Pattern` record, `PatternEvent`
  ADT, symbolic identifier types (`TemplateName`, `VoiceKey`,
  `ControlTag`, `SwapLabel`), `expandPattern :: Pattern ->
  SampleRange -> [(SamplePos, PatternEvent)]` (defensively clamps
  the result of `patternEvents` to `[srStart, srEnd)` — it is a
  safety net, not validation), and `staticEvents ::
  [(SamplePos, PatternEvent)] -> SampleRange -> [(SamplePos,
  PatternEvent)]` (the canonical static-pattern realization of
  the strict contract reading: a row built with `staticEvents
  fullList` already restricts its output to the requested range).
  Validation — `SamplePos` ordering, `VoiceKey` lifecycle,
  template / node / slot resolution, hot-swap continuity — lives
  in `checkDriverFeasibility`, not in `expandPattern`.
- `src/MetaSonic/Pattern/Corpus.hs` — the original five corpus rows
  as named top-level values, with later additive rows allowed when a
  subsequent phase needs corpus signal. Each row's `SynthGraph` uses the existing
  `tagged` mechanism (§5.2) on every node the row's `ControlTag`
  events reference; this is what makes `(NodeTag, ControlSlot) ->
  NodeIndex` resolution well-defined when the driver eventually
  consumes the corpus.
- `test/Spec.hs` additions:
  - Deterministic-expansion pins per row, with inline expected
    event lists.
  - Corpus-shape pins on each row's compiled `TemplateGraph` —
    region kernels claimed (per row's hypothesis above), fused
    inputs registered, `BusFootprint` extents.
  - A `checkDriverFeasibility` helper that walks a row's events
    against its `patternTemplates` and verifies the resolution
    invariants a driver depends on:
    - **Voice lifecycle.** Every `PEControlWrite` and `PEVoiceOff`
      references a `VoiceKey` previously bound by `PEVoiceOn` and
      not yet released. Duplicate `PEVoiceOn` on a still-open key
      is rejected.
    - **Template resolution.** Every `TemplateName` resolves
      against the *currently active* `TemplateGraph` (which is
      replaced by `PEHotSwap`).
    - **Node resolution.** Every `ControlTag`'s `NodeTag`
      resolves to a tagged node in the referenced template.
    - **Slot bounds.** Every `ctSlot` is non-negative and
      strictly less than the resolved node's control count
      (`length rnControls`).
    - **Hot-swap template continuity.** On `PEHotSwap`, every
      currently-open voice's `TemplateName` must be present in
      the swap payload. Voices whose templates the payload omits
      are reported as `HotSwapTemplateLost` and dropped from the
      open set so subsequent writes against them surface as
      `UnknownVoiceForWrite`.
    - **Non-decreasing `SamplePos`.**

    Positive cases prove the corpus rows are feasible.
    Negative cases (an out-of-range `ctSlot`, an unknown
    `NodeTag`, a hot-swap that orphans an open voice) prove the
    validator rejects malformed patterns and binds the issue ADT
    to actual evidence. This is the smallest assertion shape that
    proves a driver *could* execute the events without shipping a
    driver in 6.A.2.
- No new executable entry. No driver. Survey / bench integration
  (the layer (b) report from 6.A.1) is 6.A.3.

**Deferred to 6.A.3 (named explicitly so the gap doesn't get
rediscovered empirically).** The validator does *not* check the
§5.2 state-preservation invariants across `PEHotSwap`: a swap
payload that retains a voice's template name but moves the
voice's migration-keyed nodes to different `NodeKind`s (or drops
them entirely) would still pass v1's continuity check while
silently breaking state migration. Catching this requires either
a node-kind-and-key continuity table the pattern carries
alongside its events, or a runtime check inside the eventual
driver that reads §5.2 migration counters and flags mismatches.
6.A.3 inherits the choice.

The driver itself is deliberately deferred. Landing it before the
contract is reviewed would couple driver design to a not-yet-vetted
contract; landing it after means the contract is fixed against an
abstract consumer, which is exactly the descriptive-first discipline
the project applies elsewhere. The 6.A.2 verification gate
exercises `expandPattern` directly and proves driver feasibility
through the property test above.

The implementation can grow combinators as needed to write the
corpus, but those combinators are *consequences* of the corpus
content, not API design done in advance.

## Next concrete step

Implement `MetaSonic.Pattern` and `MetaSonic.Pattern.Corpus` to the
contract above. Add the regression pins for rows 1–5. Then 6.A.3
adds the survey / bench recognition report.
