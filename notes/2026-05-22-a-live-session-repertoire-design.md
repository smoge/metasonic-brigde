# Phase 8b — Live-Session Repertoire Design

Date: 2026-05-22

Status: design note. No code lands on the strength of this note alone.
Review first; the actual repertoire commit is a separate narrow slice
chosen after this inventory and proposal are agreed on.

Companion to
[2026-05-21-b-live-session-operator-pass-playbook.md](2026-05-21-b-live-session-operator-pass-playbook.md)
and the closure tag `phase-8-live-session-v0-operator-validated`
(commit `d6cffae`). The Phase 8 v0 live-session shell is validated;
the question this note opens is what to *play* through it next.

Primary source material:

|             Topic              |File                                                                |                    Symbol                     |
|:------------------------------:|--------------------------------------------------------------------|:---------------------------------------------:|
|     Region kernel contract     |[RegionKernels.hs](../src/MetaSonic/Bridge/Compile/RegionKernels.hs)|       `Note [Region kernel selection]`        |
|Preserving-reload classification|[RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs)     |         `preservingHotSwapNodeClass`          |
| Per-node migration validation  |[RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs)     |            `validateStatefulNode`             |
|       Per-kind ABI table       |[Types.hs](../src/MetaSonic/Types.hs)                               |                  `kindSpec`                   |
|    Manifest control schema     |[Manifest.hs](../src/MetaSonic/Authoring/Manifest.hs)               |               `ManifestControl`               |
|Preserving drone pair (current) |[Demos.hs](../app/MetaSonic/App/Demos.hs)                           |`dronePreserveSawDark`/`dronePreserveSawBright`|
| Direct ReportedControl binding |[Demos.hs](../app/MetaSonic/App/Demos.hs)                           |          `preserveCutoffControlDark`          |
|   Smoothed authoring control   |[Authoring.hs](../src/MetaSonic/Authoring.hs)                       |                   `control`                   |
|    Validated live manifest     |[preserve-cutoff.json](../examples/manifests/preserve-cutoff.json)  |                 (whole file)                  |


## Why This Arc

The validated operator pass on 2026-05-22 exercised `status`, `demos`,
`controls`, both reload forms, `help`, `quit`. No new friction
surfaced. One reason no friction surfaced is that the playable surface
was thin: one template, one control. A thicker playable surface is the
generator of friction, not infrastructure work that bypasses it.

So Phase 8b is **repertoire**, not mechanism:

- not more supervisor / preserving-reload work
- not generated fusion
- not GUI binding
- not Core DSL syntax

Goal: turn `--manifest-live-session` into something that feels like a
small playable instrument, with enough surface that a real session can
*produce* the next friction observation. Whether that next observation
points at current-value introspection, command history, control
grouping, GUI binding, or "nothing yet" is left to the pass — this
note doesn't pre-commit to a follow-up lane.


## Inventory — The Real Surface

### Optimized region kernels (the §4.B family)

Confirmed against
[RegionKernels.hs](../src/MetaSonic/Bridge/Compile/RegionKernels.hs) —
`Note [Region kernel selection]`. Seven shapes are recognized;
sink-terminal variants accept either `KOut` or `KBusOut` at the
terminal slot.

| Tag                |               Shape               | Arity | Terminal |
| ------------------ | :-------------------------------: | ----- | -------- |
| `RSawLpfGain`      |     `KSawOsc → KLPF → KGain`      | 3     | buffer   |
| `RSinGainOut`      |     `KSinOsc → KGain → sink`      | 3     | sink     |
| `RSawGainOut`      |     `KSawOsc → KGain → sink`      | 3     | sink     |
| `RNoiseGainOut`    |    `KNoiseGen → KGain → sink`     | 3     | sink     |
| `RSawLpfGainOut`   |  `KSawOsc → KLPF → KGain → sink`  | 4     | sink     |
| `RBusInLpfGainOut` |  `KBusIn → KLPF → KGain → sink`   | 4     | sink     |
| `RNoiseLpfGainOut` | `KNoiseGen → KLPF → KGain → sink` | 4     | sink     |

The existing `dronePreserveSawDark` / `dronePreserveSawBright` pair
in [Demos.hs](../app/MetaSonic/App/Demos.hs) lands on
`RSawLpfGainOut`. The noise counterpart (`RNoiseLpfGainOut`) is
unused at the App level today.

These kernels are the *optimized* path, not a fence. A demo that
falls outside the seven shapes still runs — it just stays on the
generic `RNodeLoop` executor instead of one of the fused kernels. That
matters for performance but not for whether a demo is reachable.

### Broader node-loop playable surface

`NodeKind` includes nodes that no region kernel touches today.
Available to a live-session demo as long as the preserving contract
admits them (see below):

- Other oscillators: `KTriOsc`, `KPulseOsc` — both stateful, both
  preserve-compatible.
- Other biquads: `KHPF`, `KBPF`, `KNotch` — same `[signal, cutoff, q]`
  shape as KLPF, same preserving classification.
- Routing: `KAdd`, `KBusIn`, `KBusOut`, `KBusInDelayed` — all
  preserve-compatible (stateless).

These don't fuse into the §4.B kernels but compose normally on the
node-loop path.

### Preserving-reload contract

Confirmed against
[RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs) —
`preservingHotSwapNodeClass`, the table that classifies every
`NodeKind`:

- **`PreserveUnsupported`** (a voice using any of these cannot survive
  a `require-preserving` reload):
  - `KEnv`, `KDelay`, `KSmooth`, `KPlayBufMono`, `KRecordBufMono`,
    `KSpectralFreeze`, `KStaticPlugin`, `KSpectralLpf`
- **`PreserveStateful`** (works under preserving reload; state is
  copied across the swap):
  - `KSinOsc`, `KSawOsc`, `KNoiseGen`, `KLPF`, `KPulseOsc`, `KTriOsc`,
    `KHPF`, `KBPF`, `KNotch`
- **`PreserveStateless`** (works under preserving reload; no state to
  copy):
  - `KOut`, `KGain`, `KAdd`, `KBusOut`, `KBusIn`, `KBusInDelayed`

The preserve-cutoff demo intentionally routes OSC writes *directly*
to the KLPF control input, not through `KSmooth`, because `KSmooth`
is `PreserveUnsupported`. The header comment above
`dronePreserveSawDark` in [Demos.hs](../app/MetaSonic/App/Demos.hs)
spells this out. Phase 8b inherits the same constraint: any demo
whose voice template uses an unsupported kind on the live-preserving
happy path will fail to reload. (`KDelay` is the most likely
accidental violation — it's the obvious "wet path" node and is
`PreserveUnsupported`.)

### Manifest control facts

Confirmed against
[Manifest.hs](../src/MetaSonic/Authoring/Manifest.hs) —
`ManifestControl`. It declares per-control:

- `name` — display name
- `default`, `rangeMin`, `rangeMax` — value envelope
- `smoothingHz` — declared but routes through `KSmooth` only if the
  authoring layer wires it that way (see preserve-cutoff for the
  *unrouted* convention)
- `cc` — optional MIDI CC
- `key` — migration key, the `tagged "name"` label from the source
  graph
- `slot` — control slot index within the tagged node

No `unit` field. Display layers must not invent one.

`key` + `slot` together address a control slot of a specific tagged
node. The slot index addresses the *control-defaults* list of that
kind, not its audio-input port list. For `KLPF` the control-defaults
list is two-wide (cutoff, q), per the `KLPF` row of `kindSpec` in
[Types.hs](../src/MetaSonic/Types.hs). The current preserve-cutoff
manifest uses `slot: 0` to address cutoff.

**Verify before code:** the assumption that `slot: 1` on a
`"lpf"`-tagged KLPF routes to its q port is plausible from the
schema but has not been traced through `ManifestReload` to a working
runtime write. The first thing the repertoire commit's design pass
should do is grep `rcSlot` through `Session/ManifestReload.hs` and
write a one-line note recording the actual slot→port mapping.
Similarly for `KGain` (gain amount) and `KSawOsc` (frequency, phase)
if those become control surfaces.


## Phase 8b Demo Set Proposal

A small, conservative starting set. The criteria:

1. Every voice template is preserving-compatible — no
   `PreserveUnsupported` kinds on the live path.
2. The set spans at least two **audible** dimensions of contrast, so
   reloads sound different in a meaningful way, not just numerically
   different.
3. Multiple OSC controls per voice, exposing the multi-control
   scanning question (does `controls` stay readable, do operators want
   grouping, do they keep wondering what the current value is).
4. All shapes land on existing region kernels where possible, so the
   demo set doubles as a small audit that the fused path actually
   carries the manifest live session.

### Tier 1 — single voice, multiple controls

Four single-template demos in two families. The saw family
(`saw-filter-dark`, `saw-filter-bright`) lands on `RSawLpfGainOut`;
the noise family (`noise-filter-soft`, `noise-filter-sharp`) lands
on `RNoiseLpfGainOut`. Each demo is one voice template — *not* an
ensemble. Multi-template authoring belongs to Tier 2.

**Control binding constraint.** Every control on every voice must be
a direct `ReportedControl` binding to a tagged primitive node — the
same shape as `preserveCutoffControlDark` in
[Demos.hs](../app/MetaSonic/App/Demos.hs). Do *not* route the
controls through `Auth.control` or `ccControl`. Those helpers emit a
`KSmooth` node on the control path (see `control` in
[Authoring.hs](../src/MetaSonic/Authoring.hs)), and `KSmooth` is
`PreserveUnsupported`. Using them would break preserving compatibility
*and* push the voice off the §4.B kernel shape this demo set is meant
to exercise. The preserve-cutoff drone already follows this rule and
is the working precedent.

```text
saw-filter-dark
  carrier:  KSawOsc   freq = 220 Hz (control: "pitch", slot ?, range [55, 880])
  lpf:      KLPF      cutoff = 600 Hz (control: "cutoff", slot 0, range [200, 6000])
                      q      = 0.7    (control: "q",      slot 1, range [0.3, 4.0])
  shaped:   KGain     amount = 0.2    (control: "level",  slot ?, range [0.0, 0.5])
  sink:     KOut 0

saw-filter-bright    -- same shape; cutoff default = 2400, level slightly hotter

noise-filter-soft
  source:   KNoiseGen
  lpf:      KLPF      cutoff = 900 Hz, q = 1.0
  shaped:   KGain     amount = 0.15
  sink:     KOut 0

noise-filter-sharp   -- same shape; cutoff = 3200, q = 3.0
```

This gives four demos in two preserving-compatible pairs. Reload from
`saw-filter-dark` to `saw-filter-bright` is the same migration the
current preserve-cutoff pair exercises; reload from
`noise-filter-soft` to `noise-filter-sharp` is the same idea on the
noise counterpart. Cross-source reloads (saw ↔ noise) are expected to
*reject* under `require-preserving` unless migration keys, node kinds,
and control counts all line up. The reject mechanism is
`validateStatefulNode` in
[RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs),
which validates each stateful node in the new graph against the
same-keyed node in the old graph on three counts: key presence,
kind match, and control-length match. If both families share
`tagged "lpf"` for their KLPF nodes the filter migrates fine; but
the source node — `tagged "carrier"` as `KSawOsc` in one family and
something like `tagged "carrier"` as `KNoiseGen` in the other — fails
the `rnKind oldNode /= rnKind node` arm. That kind-mismatch reject is
behavior worth observing in the operator pass, and it's a preserving
reject arm the existing fixture set does not exercise (see Open
Question below).

Slot indices marked `?` are the ones that need verification before
the demo lands. The cutoff binding is known-good from preserve-cutoff;
the rest needs the source pass described above.

### Tier 2 — send/return (defer)

`RBusInLpfGainOut` exists and is preserving-compatible. A voice
template writes to a bus, an fx template reads it. This adds:

- multi-template ensembles in one manifest
- bus index management
- audible "dry/wet" distinction without leaning on `KDelay`

But it also tests more system surface (template precedence, bus
allocation) at once, and the user's last instruction was to start
conservative. So Tier 2 is recorded here for traceability and *not*
opened in the first repertoire commit.

### Explicitly out of scope for Phase 8b

- `KSmooth`-routed controls on the live-preserving happy path
  (would force reject; only relevant to the existing
  `reject-preserving-smooth.json` sibling).
- `KDelay` / `KEnv` / `KPlayBufMono` voices on the live-preserving
  happy path (same reason — they're `PreserveUnsupported`).
- Generated fusion or new kernel shapes — the current seven are
  sufficient.
- Multi-output / stereo voices — the existing surface is mono `KOut 0`;
  widening would be a separate slice with its own evidence.
- GUI binding, command history, ALSA stderr handling, current-value
  introspection — held as candidate follow-up lanes, not opened by
  this arc.


## Evidence Bar

Same shape as the validated 2026-05-22 pass:

1. **Verify slot mapping.** One source pass through `ManifestReload`
   to record the actual `slot → port` mapping for `KLPF`, `KGain`,
   `KSawOsc`. Record the result in a one-line note (or amend this
   note) before writing the demo set. If the mapping turns out to be
   per-kind awkward (e.g. requires authoring-side `tagged` on each
   parameter separately), narrow the demo set rather than working
   around it.

2. **Land the repertoire.** Narrow commit. New `Demos.hs` entries
   plus one or two new manifests under `examples/manifests/`. No
   shell changes, no introspection, no GUI, no kernel work.

3. **Operator pass.** Audio-paired, not scripted. Use the demos
   musically: reload, change controls over OSC/MIDI, scroll back,
   reprint `controls`, swap voices. Capture one transcript under
   `/tmp/`. Do not over-script — the point is to surface friction,
   not validate a checklist.

4. **Findings entry.** Append one section to
   `2026-05-21-b-live-session-operator-pass-playbook.md`. Answer
   honestly:

   - Did multi-control `controls` output stay readable?
   - Did current-value introspection feel missing, or did it not
     come up?
   - Did command history feel missing?
   - Did `demos` need grouping (e.g. by family) once there were four
     entries?
   - Was the audible contrast between dark/bright and soft/sharp
     enough to make the reload feel musical?
   - Did anything else surface that none of the four candidate lanes
     names?

5. **Let that pass decide the next slice.** Per the rubric in the
   playbook: real operator pressure names the next lane. This note
   does not pre-commit to any of:
   - current-value introspection (architectural — design note first)
   - command history / line editing (narrow shell slice)
   - control grouping (narrow renderer slice)
   - GUI / control binding (out of scope until terminal stops being
     enough)


## Open Questions To Resolve Before Code

These are deliberately small and concrete:

- **Slot→port mapping** for `KLPF` (slot 1 = q?), `KGain` (slot for
  amount?), `KSawOsc` (slot for freq? slot for phase? — phase is
  `PortIgnored`, so even if exposable it should not be in the demo
  set's UI surface).
- **Cross-source preserving behavior is untested.** The existing
  `reject-preserving-smooth` fixture covers the
  `PreserveUnsupported`-kind reject arm only — a voice with
  `KSmooth` cannot survive *any* preserving reload, so the rejection
  is observed before the per-node migration validation in
  `validateStatefulNode`
  ([RTGraphAdapter.hs](../src/MetaSonic/Session/RTGraphAdapter.hs))
  even runs. It does *not* cover the cross-kind reject case where
  two voices share migration keys but their tagged source nodes
  differ in `NodeKind` (e.g. `tagged "carrier"` as `KSawOsc` vs
  `KNoiseGen`). Phase 8b's saw ↔ noise reloads would be the first
  fixture to exercise that arm. Whether the observed kind-mismatch
  reject is interesting evidence — a meaningful "you can't cross
  families under preserving" signal — or just noise depends on the
  operator pass.
- **Manifest count.** One manifest with four demos, or two manifests
  with two demos each? One file keeps the operator's single-load
  workflow intact; two files let the operator switch between
  unrelated *families* by relaunching. Recommend one file for the
  first pass — easier to A/B against preserve-cutoff in the same
  session — and split only if the four-demo `demos` output becomes
  hard to scan.
