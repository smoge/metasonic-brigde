## Phase 6.E — Second Static Plugin Contract (one-tap delayed sum)

Date: 2026-05-19

Status: **landed**. The contract body below is preserved as the
design record the implementation slice was reviewed against; the
"Implemented status" section immediately below this header is the
authoritative summary of what shipped, with the commit chain and
the remaining deferrals. The contract was the
"small design note" the
[Phase 6.E.3 plugin metadata decision](2026-05-11-n-phase-6e3-plugin-metadata-decision.md)
asked for before a second static plugin entered the runtime. The
companion v1 contract for the first plugin kind is
[Phase 6.E plugin-hosting design](2026-05-11-h-phase-6e-plugin-hosting-design.md);
this note adopts the same shape and only resolves the questions the
v1 note explicitly left open for the next plugin. Shape mirrors
[Phase 6.D second spectral kind contract](2026-05-19-c-phase-6d-second-spectral-kind-contract.md)
because the same "second user proves the seam" discipline applies.

The original pre-implementation framing has been retained verbatim
below from §0 onward so future readers can reconstruct what the
slice was being held to, what the contract considered and rejected
(§1's alternatives, §9's Q-deferrals), and how the §7 site table
ordered the work.

## Implemented status

Landed across ten commits between the contract-note merge
(`200c4b5`) and the closeout sync, in the same §7 ordering the
contract prescribed:

| # | Commit | Slice content |
|---|--------|---------------|
| 1 | `7988150` | Prep: `kMaxPluginState` in `tinysynth/rt_graph_plugins.h` inside `namespace metasonic`; `StaticPluginState` gains an `alignas(std::max_align_t) std::array<std::byte, kMaxPluginState>` inline storage blob; `static_assert` pinning the §4.1 free-ride invariant against `SpectralFreezeState`. |
| 2 | `d1a0fed` | Step 2: `tinysynth/plugins/one_tap_delay.cpp` (two-input one-sample-delayed sum, null-as-zero on each input mirroring `identity.cpp`); registered after Identity in `ensure_builtin_plugins_registered`; both `package.yaml` `cxx-sources` and `CMakeLists.txt` updated in lockstep; §4.2 bounds check on `register_plugin` (`state_size_bytes ∉ [0, kMaxPluginState]` → `-1`). |
| 3 | `a4c8ff2` | Step 3: §5 #13 C++ doctest cases for `register_plugin` bounds (just-past-upper-bound, `-1`, `INT_MIN`, inclusive upper-bound accept). |
| 4 | `d806e98` | Step 4 / site 14: `process_static_plugin` passes `st->storage.data()` when `state_size_bytes > 0`, keeps `nullptr` for Identity. `spec->init` remains uncalled in v2. |
| 5 | `fc3cced` | Doctest hardening: "registry exposes one-tap-delay" smoke; accept-case `PluginSpec` moved to function-local `static` so `register_plugin`'s stored pointer outlives the test. |
| 6 | `64c6b92` | Dispatch smoke (`KStaticPlugin` builds a real one-tap-delay node via the template ABI; asserts `plugin_call_count == 1 ∧ invalid_plugin_call_count == 0`); pins plugin id 1 in the registry smoke; refreshes the stale `StaticPluginState` comment that still pointed at a future dispatcher slice. |
| 7 | `47e28ad` | Sites 1–3 (Haskell): `oneTapDelayPlugin :: PluginRef`, second `staticPluginCatalog` row at `spiPluginId = 1`, and `staticPluginInfoById` / `finitePluginId` / `maxExactPluginId` accessors with module-level exports. |
| 8 | `3f07985` | Sites 4–6 / 6a / 6b: `nodeDeclaredLatency` in `Compile/Latency.hs`; three consumers migrated (`declaredLatencyFootprint`, `nodeOutputLatencies`, `FusionCostLab.extractFeatures`); user-facing wording refreshed in `Survey.hs`'s latency footprint header and the `Compile/Latency.hs` module header. |
| 9 | `c037b50` | Sites 17 / 17a / 17b: 13 cases in `oneTapDelayPluginTests` (`Feature/StaticPlugin.hs`) + 2 cases in new `MetaSonic.Spec.AppFusionCostLab` module + test-component `other-modules` wiring (`MetaSonic.App.FusionCostLab`, `MetaSonic.App.FusionCostModel`, `MetaSonic.Spec.AppFusionCostLab`). |
| 10 | `0152a8b` | Review pass: `c_rt_graph_ensure_bus rt 1` in test #10 before the per-instance bus override; `readBus` helper asserts the read count equals `n` (closes a false-negative path on any "bus N is silent" assertion); three stale Identity-only Haddock spots in `Bridge/Source.hs` refreshed. |

Test count delta: Haskell suite 1161 → 1178 (+17); C++ doctest
suite 314 → 317 (+3). Both build paths (`stack` via `cxx-sources`
and the standalone `cmake` build into `build-cpp/`) compile clean
and all assertions pass.

The slice landed §7 step 1 through step 7 verbatim. Two material
departures from the §5 / §7 sketches, both reducing scope rather
than adding it:

- §5 case #10 (two-voice state independence) ships against a
  simpler `loadTemplateGraph + c_rt_graph_template_instance_add +
  per-instance busOut override` pattern rather than the contract's
  `loadTemplateGraphWithAutoSpawns + remove + realtime_reserve ×2 +
  realtime_activate` dance. Same leak catches with less plumbing;
  the false-negative window where voice B writes to a non-existent
  bus is closed by the `c_rt_graph_ensure_bus` call + the `readBus`
  length assertion landed in `0152a8b`.
- The contract sketched §5 cases #1–#13 (Haskell side) plus #4a /
  #5a / #8a as additions; the landed test count is 13 cases in
  `StaticPlugin.hs` + 2 cases in `AppFusionCostLab` (15 total)
  rather than the contract's ~16. Coverage matches; some
  contract-numbered cases were bundled tighter inside a single
  test where the assertions were natural neighbors.

Deferrals stay parked behind a forcing-function plugin, as
§4 / §8 / §9 already pinned:

- `spec->init` / `spec->reset` callbacks (§4 / §9 Q-4). v2 calls
  neither. The init-seam follow-up note will choose between
  producer-thread init via a reshaped `init_node_state` signature
  and RT-safe-by-contract init from `process_static_plugin`. Forcing
  function: a stateful plugin whose correct initial state is not
  all-zeros — most likely a sample-rate-dependent filter.
- Per-plugin resource effects (§8). Both catalog rows declare
  `[Pure]`. A bus-reading / bus-writing / buffer-touching plugin
  needs the node-specific resource-metadata path the v1 §6.E design
  flagged before `inferEff` for `KStaticPlugin` can honestly return
  non-`Pure`.
- Plugin parameters (§8 / §6.E Q-4). The fixed
  `staticPlugin ref in0 in1` surface is preserved; parameter
  layout / modulation stays parked.
- Plugin state migration across hot-swap (§8).
  `node_kind_supports_state_migration KStaticPlugin = false` stays;
  the new per-instance `storage` blob does not opt into Phase 5.2
  migration.
- LV2 / VST3 / CLAP adapter kinds, dynamic loading / plugin
  discovery, plugin-owned UI, MIDI-in plugins, and multichannel
  plugins (§8) remain parked.
- Per-plugin scheduling refinement (§8). `KStaticPlugin` stays
  uniformly `CapHardBarrier`; relaxing this for stateless or
  latency-bearing-only plugins is a §6.E.3 follow-up.

Forcing-function rule: every parked item reopens only when a real
plugin pulls the contract in a specific direction. Pinning any of
them ahead of that user repeats the speculative-design pattern
§6.E.3 explicitly rejected.

Read this before writing any runtime code. The intent is for the
implementation slice to mirror this note line-for-line, the same way
the freeze and lpf series mirrored their designs.

## 0. Anchors

- The first plugin kind is `KStaticPlugin` at tag `23`
  ([src/MetaSonic/Types.hs:306-314](../src/MetaSonic/Types.hs)),
  `kindLatency KStaticPlugin = Nothing`
  ([src/MetaSonic/Types.hs:566-570](../src/MetaSonic/Types.hs)),
  `kindCapabilities` row `[CapHardBarrier]`
  ([src/MetaSonic/Types.hs:676](../src/MetaSonic/Types.hs)),
  `inferEff (StaticPlugin _ _ _) = [Pure]` for the only catalog row
  ([src/MetaSonic/Bridge/Source.hs:1568-1569](../src/MetaSonic/Bridge/Source.hs)).
  State lives per-instance in `StaticPluginState`
  ([tinysynth/rt_graph.cpp:878-881](../tinysynth/rt_graph.cpp)),
  currently `{plugin_id, spec}` with **no inline host-owned
  storage** — `process_static_plugin` passes `state = nullptr` to
  `spec->process`
  ([tinysynth/rt_graph.cpp:5642-5648](../tinysynth/rt_graph.cpp)),
  on the grounds that v1 Identity declared `state_size_bytes = 0`.
- The Haskell catalog
  ([src/MetaSonic/Bridge/Source.hs:225-247](../src/MetaSonic/Bridge/Source.hs))
  has exactly one row: `identityPlugin` at `plugin_id = 0`,
  arity 2 → 1, `spiLatencySamples = 0`, `spiEffects = [Pure]`,
  `spiLabel = "identity"`. The next free plugin id is **`1`**.
- The runtime registry (`tinysynth/rt_graph_plugins.cpp`) registers
  built-ins through `ensure_builtin_plugins_registered`; today it
  contains exactly one call: `register_plugin(identity_plugin_spec())`.
- `declaredLatencyFootprint` and `nodeOutputLatencies` in
  [src/MetaSonic/Bridge/Compile/Latency.hs](../src/MetaSonic/Bridge/Compile/Latency.hs)
  both consult `kindLatency (rnKind n)` directly. They will see a
  zero-latency story for every `KStaticPlugin` node until a
  plugin-aware accessor lands.
- The Planner's `checkNonSinkAt`
  ([src/MetaSonic/Bridge/Planner.hs:317-336](../src/MetaSonic/Bridge/Planner.hs))
  rejects `KStaticPlugin` mid-chain through `CapHardBarrier`
  (`ReasonHardBarrier`), strictly stronger than the
  `CapLatencyBearing` path (`ReasonLatencyMidChain`). Adding a
  latency-bearing plugin therefore does **not** change planner
  behavior in v2.
- The `inferEff` path is already per-`UGen` data-dependent
  ([src/MetaSonic/Bridge/Source.hs:1568-1569](../src/MetaSonic/Bridge/Source.hs)):
  it routes through `staticPluginInfo ref` to `spiEffects`. A second
  catalog row with `spiEffects = [Pure]` slots in without touching
  the call site.

## 1. Choice: `oneTapDelayPlugin` — two-input, one-sample-delayed sum

Pick a **two-input one-sample-delayed sum** as the second catalog
row. It is the smallest *new* plugin behavior that exercises every
piece of the v1 hosting protocol that Identity left untested,
without forcing any new kind, new arity, new DSL surface, or new
resource vocabulary. Specifically it proves:

- Second catalog row coexisting with Identity through the
  Haskell-side lookup (the path
  [Phase 6.E.3](2026-05-11-n-phase-6e3-plugin-metadata-decision.md)
  designed but never had a second user for).
- Real per-instance plugin state plumbed through
  `StaticPluginState` — `process` receives a non-null `state`
  pointer for the first time.
- Declared per-plugin latency surfacing through a
  plugin-aware accessor (not through `kindLatency`).
- Counter-confirmed dispatch independence across plugin ids on
  the same `KStaticPlugin` kind.

Alternatives considered and rejected for this slice:

- **One-tap *single-input* delay.** Symmetric DSP shape, slightly
  smaller surface. Rejected because it does not test that the host
  correctly wires *both* audio inputs to a plugin with non-trivial
  state — Identity already proved both inputs route through the
  vtable, but only with a pure pointwise body. A two-input stateful
  body catches a wider class of dispatch mis-wirings (state
  pointer mixed with one of the input pointers, etc.).
- **A second pure plugin** (e.g. a soft-clip / `tanh` saturator).
  Same arity as Identity but no state, no declared latency. It
  would not exercise the two pieces of v1 plumbing that have
  remained untested (`state` parameter to `process`, plugin-aware
  latency lookup) — exactly the pieces the catalog scaffold in
  [§6.E.3](2026-05-11-n-phase-6e3-plugin-metadata-decision.md)
  was put in place to unblock.
- **A buffer-touching plugin** (e.g. a small convolution against a
  shared sample buffer). Would force `inferEff` for `KStaticPlugin`
  to start returning non-`Pure` effects, which the v1 hosting
  design explicitly parked behind "a future series adds a
  node-specific resource-metadata path"
  ([§6.E §3 / §6.E.3 Initial Scope](2026-05-11-h-phase-6e-plugin-hosting-design.md)).
  That is the right next step *after* this slice, not in it.
- **A plugin with parameters** (e.g. a one-pole LPF whose cutoff
  is a plugin parameter). Forces v1's parked
  parameter-layout/modulation decision
  ([§6.E Q-4](2026-05-11-h-phase-6e-plugin-hosting-design.md)).
  This slice keeps the fixed `staticPlugin ref in0 in1` DSL surface
  unchanged — the second row uses the same shape Identity does.

The point of this row is not the DSP body — it is to surface
exactly which pieces of the v1 hosting plumbing were untested by
Identity, and to land the minimum amount of new infrastructure
each one needs.

### Important non-claim: `Eff` is not "stateful DSP"

The current `Eff` vocabulary
([src/MetaSonic/Types.hs §990-1010](../src/MetaSonic/Types.hs))
is `Pure`, `BusRead n`, `BusReadDelayed n`, `BusWrite n`,
`BufRead`, `BufWrite`. Every non-`Pure` entry describes a
*shared-resource interaction* (bus or buffer), which feeds bus /
buffer ordering edges in `E_r` and inter-template precedence.

A one-tap delay plugin carries per-instance cross-sample state but
**does not** read or write any shared bus or buffer. Its effect
remains `[Pure]`. Calling it a `BufRead` / `BufWrite` would be a
type-level lie that would induce phantom precedence edges and
break the §6.C.4 / §6.C.5 single-writer invariants.

The §6.E v1 design correctly pinned this: future plugins that
*do* read/write buses or buffers need a per-node metadata path
before they can claim non-`Pure` effects without breaking the
per-kind-or-per-UGen current API. This slice does **not** open
that path. Resource-declaring plugins remain parked.

The per-plugin latency lookup is therefore the *only* metadata
surface this slice broadens. That is the smallest honest step the
catalog scaffold can take with a second consumer.

## 2. Contract

| Property                  | Value                                              |
|---------------------------|----------------------------------------------------|
| Plugin id                 | `1` (first slot after `identityPlugin = 0`)        |
| Haskell ref               | `oneTapDelayPlugin :: PluginRef`                   |
| `pluginRefName`           | `"one-tap-delay"`                                  |
| `spiAudioInputs`          | `2`                                                |
| `spiAudioOutputs`         | `1`                                                |
| `spiLatencySamples`       | `1`                                                |
| `spiEffects`              | `[Pure]`                                           |
| `spiLabel`                | `"one-tap-delay"`                                  |
| C `PluginSpec.name`       | `"one-tap-delay"` (string must match `spiLabel`)   |
| C `state_size_bytes`      | `sizeof(OneTapDelayState)` (4 bytes, single float) |
| `NodeKind`                | `KStaticPlugin` (unchanged)                        |
| Kind tag                  | `23` (unchanged)                                   |
| `kindLatency KStaticPlugin` | `Nothing` (unchanged — see §3)                   |
| `kindCapabilities`        | `[CapHardBarrier]` (unchanged — see §3)            |
| DSL                       | `staticPlugin oneTapDelayPlugin in0 in1` (same surface as Identity) |
| Multichannel              | Mono only (unchanged)                              |
| Plugin parameters         | None (unchanged)                                   |

DSP body (audio-thread, per block of `nframes`):

```text
prev = state.prev_sum                  // carried from previous block
a    = in0 == nullptr ? zero-vec : in0  // null-as-zero, mirrors Identity
b    = in1 == nullptr ? zero-vec : in1
for i in 0 .. nframes-1:
    sum     = a[i] + b[i]
    out[i]  = prev                     // emits the previous sample's sum
    prev    = sum
state.prev_sum = prev                  // carry into the next block
```

**Null-input handling: mirrors Identity.** When `process` receives
`inputs[k] == nullptr`, the kernel treats that channel as
silence (`0.0f` for every sample). This is the same contract
[identity.cpp:17](../tinysynth/plugins/identity.cpp) already pins:
`const float av = a == nullptr ? 0.0f : a[i];`. The host
(`process_static_plugin` at
[rt_graph.cpp:5628-5639](../tinysynth/rt_graph.cpp)) passes
`nullptr` for any input whose `resolve_input` returns an empty
span, which is exactly what happens for `RConst` (`Param`) inputs
because the FFI loader at
[FFI.hs:2222](../src/MetaSonic/Bridge/FFI.hs) does not wire a
buffer for them. Without this null-as-zero handling on the
one-tap-delay side, the §5 tests that pass `Param 0.0` for `in1`
would dereference `nullptr` (UB) instead of correctly summing
against zero. Pinning the contract here keeps the tests at the
same DSL ergonomics Identity already uses.

Initial conditions:

- `state.prev_sum = 0.0f` at instance reset (zero-initialized blob
  via `init_node_state`; see §4).
- First block's `out[0] = 0.0f` (the "previous sum" before any
  audio is zero). Subsequent samples carry the previous sample's
  sum.
- Across block boundaries `state.prev_sum` is the last sample's
  `a + b` of the previous block (where `a` / `b` are the
  null-as-zero resolved inputs). The 1-sample latency declaration
  is exact and observable: feeding an impulse at `in0[k]` (with
  `in1` passed as `Param 0.0` so the kernel sees `b == nullptr`
  and treats it as zero) produces a unit sample at `out[k+1]`,
  with `out[0..k]` and `out[k+2..]` being zero.

Explicitly **not** in v1 of this row:

- N-tap delay (variable latency). The whole point of a v2 row is
  to pin a single observable latency; configurable delays are a
  later parameter-bearing-plugin question.
- Feedback (`out[i]` feeding back into `state.prev_sum`).
  Stability and bounded growth are unanalyzed; no feedback in v1.
- Stereo / wider input arities. The fixed
  `staticPlugin ref in0 in1` surface is preserved.
- A separate `KOneTapPlugin` `NodeKind`. The v1 §6.E design and
  the §6.E.3 decision both pin "one kind, plugin facts on the
  catalog" — this slice honors that.

## 3. Per-plugin latency lookup (the only new compiler surface)

Add a plugin-aware accessor that consumes a `RuntimeNode`
(which carries `rnKind` and `rnControls`) and resolves declared
latency through the catalog when `rnKind == KStaticPlugin`.
Preserves the `kindLatency` invariant that *zero latency is
reported as `Nothing`, not `Just 0`*: this lets `nodeDeclaredLatency`
be a drop-in replacement at every existing `kindLatency`-via-node
call site without re-shaping the downstream filter logic, and keeps
Identity invisible to `declaredLatencyFootprint` (whose existing
filter is `lat > 0`) without that filter doing the work for us.

```haskell
-- New, in MetaSonic.Bridge.Source (adjacent to staticPluginInfo).
-- Catalog has at most a handful of rows for the foreseeable future,
-- so a linear scan is fine.
staticPluginInfoById :: Int -> Maybe StaticPluginInfo
staticPluginInfoById pid =
  find ((== pid) . spiPluginId) staticPluginCatalog

-- New, in MetaSonic.Bridge.Source. Safe parser for the frozen
-- plugin_id control-slot value. Returns Nothing for any value that
-- is not finite, non-negative, in range, and integral within a
-- small tolerance.
--
-- Bounds order matters:
--   1. NaN / Inf rejected first (round NaN is undefined; isFinite
--      via not-NaN-and-not-Inf is the actual sentinel here).
--   2. Negative rejected — plugin ids are non-negative by definition.
--   3. **Upper-bound rejected before the Int conversion.** round (1e100)
--      :: Int is implementation-defined nonsense on every supported
--      target. The strictly-less-than-2^53 bound is exclusive: at
--      exactly 2^53 the gap between adjacent representable Doubles
--      becomes 1.0, so the +1 successor (2^53 + 1) silently rounds
--      to 2^53 and an "almost-integer" tolerance check would
--      pass values that are not actually distinguishable from
--      adjacent integers. Strict d >= maxExactPluginId makes that
--      boundary observable in the test surface. Clamped to
--      maxBound :: Int so a hypothetical 32-bit target stays safe.
--   4. Integrality check uses a symmetric ±1e-9 epsilon around the
--      nearest integer. An honest plugin_id is fromIntegral i :: Double
--      for i :: Int, which is exact for any id strictly below 2^53 —
--      the epsilon catches accidental arithmetic on the control slot
--      (e.g. a 0.5 from a half-resolved live write) without
--      false-rejecting honest ids.
-- Exclusive upper bound for finitePluginId. Lifted to module
-- level (rather than a `where` binding inside finitePluginId) so
-- the §5 #4a accept-boundary test can reference the same constant
-- the parser uses. Exported from MetaSonic.Bridge.Source alongside
-- finitePluginId and staticPluginInfoById.
maxExactPluginId :: Double
maxExactPluginId =
  min (2 ** 53) (fromIntegral (maxBound :: Int))

finitePluginId :: Double -> Maybe Int
finitePluginId d
  | isNaN d                              = Nothing
  | isInfinite d                         = Nothing
  | d < 0                                = Nothing
  | d >= maxExactPluginId                = Nothing
  | abs (d - fromIntegral asInt) > 1e-9  = Nothing
  | otherwise                            = Just asInt
  where
    asInt :: Int
    asInt = round d

-- New, in MetaSonic.Bridge.Compile.Latency (consumer-side, to
-- avoid the Types.hs ↔ Source.hs import cycle; see §9 Q-5).
-- Returns Nothing for any kind whose declared latency is zero or
-- absent, including KStaticPlugin rows whose catalog row reports
-- spiLatencySamples == 0 (Identity) and KStaticPlugin nodes whose
-- frozen plugin_id is unresolvable. This preserves the
-- "Nothing means zero latency" invariant that kindLatency already
-- carries, so existing call sites do not need to learn to filter
-- out Just 0.
nodeDeclaredLatency :: RuntimeNode -> Maybe Int
nodeDeclaredLatency n =
  case rnKind n of
    KStaticPlugin -> do
      pidD <- listToMaybe (rnControls n)
      pid  <- finitePluginId pidD
      info <- staticPluginInfoById pid
      let lat = spiLatencySamples info
      if lat > 0 then Just lat else Nothing
    other -> kindLatency other
```

Migrate the three existing consumers of `kindLatency (rnKind _)`
to `nodeDeclaredLatency`:

- `declaredLatencyFootprint` in
  [Compile/Latency.hs:63-69](../src/MetaSonic/Bridge/Compile/Latency.hs)
  — the `Just lat <- [kindLatency (rnKind n)]` pattern becomes
  `Just lat <- [nodeDeclaredLatency n]`. The downstream `lat > 0`
  filter is redundant under the new accessor but should stay as a
  belt-and-suspenders guard.
- `nodeOutputLatencies` in
  [Compile/Latency.hs:77-85](../src/MetaSonic/Bridge/Compile/Latency.hs)
  — the `own = maybe 0 id (kindLatency (rnKind n))` line becomes
  `own = maybe 0 id (nodeDeclaredLatency n)`. Identity returns
  `Nothing` and so contributes zero own-latency; one-tap-delay
  contributes 1.
- `extractFeatures` in
  [app/MetaSonic/App/FusionCostLab.hs:548](../app/MetaSonic/App/FusionCostLab.hs)
  — the `latencies = [ lat | n <- nodes, Just lat <- [kindLatency (rnKind n)] ]`
  line becomes
  `latencies = [ lat | n <- nodes, Just lat <- [nodeDeclaredLatency n] ]`.
  This is the path that derives `fcfLatencyNodes` and
  `fcfMaxLatency`; without this migration, a one-tap-delay plugin
  would be invisible to the cost-lab feature row even though the
  declared-latency footprint and survey output report it.

The principle is that all *descriptive* latency reporting reads
through one accessor; per-instance latency entered the system in
this slice, so every consumer that paints a latency picture for
the user has to consult the per-instance shape.

### User-facing wording that becomes false

Once one-tap-delay rows enter `declaredLatencyFootprint`
through `nodeDeclaredLatency`, two user-visible strings
become false and must be refreshed in the same commit as the
accessor migration:

- [Survey.hs:2209](../app/MetaSonic/App/Survey.hs)'s header
  line currently reads
  `─── Declared-latency footprint (§6.D, kindLatency-bearing nodes) ───`.
  After the migration, the footprint is no longer
  kind-bearing-only — `KStaticPlugin` rows with a one-tap
  catalog row appear in the same table even though
  `kindLatency KStaticPlugin == Nothing`. Replace with
  `─── Declared-latency footprint (§6.D / §6.E, declared per node) ───`
  (or equivalent; the implementation slice can pick the exact
  wording, but `kindLatency-bearing` must go).
- [Compile/Latency.hs:9-12](../src/MetaSonic/Bridge/Compile/Latency.hs)'s
  module header comment says
  "It consumes the existing 'kindLatency' metadata on compiled
  'RuntimeGraph's and reports where inherent node latency
  appears." After the migration, it consumes
  `nodeDeclaredLatency`, which is per-instance for
  `KStaticPlugin` and kind-level for every other kind.
  Refresh the comment accordingly (one sentence change; the
  module's purpose is unchanged).

Both updates are mechanical, but they have to land with the
accessor migration — running the survey after the migration
without the header fix would print a wrong label next to the
correct numbers, which is the kind of drift the project's
contract-note discipline exists to prevent.

`Planner.checkNonSinkAt`
([src/MetaSonic/Bridge/Planner.hs:317-336](../src/MetaSonic/Bridge/Planner.hs))
deliberately stays on `kindLatency` — `KStaticPlugin` is uniformly
`CapHardBarrier`, so its mid-chain rejection path is
`ReasonHardBarrier`, not `ReasonLatencyMidChain`. Switching the
planner accessor would only change the rejection *reason* string
the planner reports, never the rejection outcome. Out of scope for
this slice; revisit if/when `KStaticPlugin` stops being
`CapHardBarrier` (see [§6.E.3](2026-05-11-n-phase-6e3-plugin-metadata-decision.md)).

### What stays in `NodeKind`-keyed metadata

- `kindLatency KStaticPlugin = Nothing` — still the kind-level
  truth, because the kind itself does not declare a fixed latency.
- `kindCapabilities KStaticPlugin = [CapHardBarrier]` — still the
  kind-level truth. A latency-bearing per-plugin row does **not**
  satisfy the kind-level `CapLatencyBearing` biconditional
  documented in
  [Note [Per-kind capability table]](../src/MetaSonic/Types.hs),
  because that biconditional explicitly reads
  `CapLatencyBearing iff kindLatency k is Just _`. Both sides
  remain false for `KStaticPlugin`; the biconditional still holds.
- `kindSpec`, `kindTag`, `ksRate`, `ksAudioArity`, `ksControlArity`,
  `ksLabel`, `portInfo` — all kind-level, all unchanged.

### Cap-bicondition test still holds

The
[`kindCapabilities` cross-table biconditionals](../src/MetaSonic/Types.hs)
test must keep passing after this slice. Concretely:

- `CapLatencyBearing iff kindLatency k is Just _`: still holds
  (`KStaticPlugin` is neither, and the row keeps `Nothing`).
- `CapResourceAccess iff representative UGen has non-`Pure`
  `inferEff``: still holds (both catalog rows are `Pure`).

If any test under [test/Spec.hs](../test/Spec.hs) gates on these,
no row update is needed; both stay false.

## 4. New seam: `StaticPluginState` gains host-owned state storage (no `init` call in this slice)

The v1 design pinned a fixed-size inline blob on `StaticPluginState`
([§6.E §2.1](2026-05-11-h-phase-6e-plugin-hosting-design.md)) but
the v1 implementation deferred it on the grounds that Identity
declared `state_size_bytes = 0`. The one-tap delay row is the first
user that actually needs it.

**Important: this slice does not call `spec->init` from anywhere.**
The v1 hosting contract
([§6.E §2.2 / §2.4](2026-05-11-h-phase-6e-plugin-hosting-design.md))
pins `init` / `reset` as **producer-thread callbacks** and `process`
as the **only audio-thread callback**. Two seams would honor that
contract:

- *Producer-thread init.* Call `spec->init` from `init_node_state`
  with the live `g.sample_rate` and `g.max_frames`.
  Blocked by the existing `init_node_state` signature
  ([rt_graph.cpp:1713](../tinysynth/rt_graph.cpp)):
  `(NodeInstanceState&, const NodeSpec&, int max_frames)` — no
  `RTGraph` parameter, and the live `g.sample_rate` is only set at
  [rt_graph.cpp:11259](../tinysynth/rt_graph.cpp) when
  `rt_graph_start_audio` opens the stream. Reshaping the signature
  to take `RTGraph &g` is a real change that lands a separate
  contract — it crosses the `init_node_state` invariant that no
  per-instance reset reads from the graph, which a handful of other
  kinds depend on.
- *Lazy audio-thread init.* Call `spec->init` from inside
  `process_static_plugin` on the first dispatch. This is what
  existing sample-rate-dependent kinds (`KEnv`, `KDelay`, `KSmooth`,
  `KLPF`, oscillators) do for their *own* state, but those kinds'
  `init` paths are q_lib constructors the team accepts as RT-safe
  by convention. Lifting that into a generic `PluginSpec::init`
  callback would silently redefine the v1 contract: every future
  plugin's `init` would now be required to be RT-safe, even though
  the v1 design header explicitly says it isn't. That is a real
  contract break and would be silent — no compile error catches it,
  only a real-world realtime audit ever would.

This slice picks **neither**. For one-tap-delay specifically,
zeroed `storage[]` is the correct initial state (the running sum
starts at zero), so omitting the `init` call costs nothing
observable. The smaller scope is: ship the inline storage path
without any new `init`-call site, and defer the init-seam decision
to a separate contract whose sole job is to pick which of the two
seams above lands first.

The next stateful plugin that genuinely needs sample-rate-dependent
init (a one-pole LPF whose coefficient depends on `g.sample_rate`,
say) is the right forcing function for that decision — at that
point there is a concrete second user pulling the contract in a
specific direction. Pinning the seam ahead of that user is
exactly the speculative move §6.E.3 rejected for plugin metadata
broadly.

The minimum amount of new C++ that makes this slice work is:

### 4.1 Inline blob on the state struct, free-riding on spectral state

The `kMaxPluginState` constant is declared in
`tinysynth/rt_graph_plugins.h` inside `namespace metasonic`
(see site 10). It is **not** redeclared in `rt_graph.cpp`. The
struct in `rt_graph.cpp` looks like:

```cpp
struct StaticPluginState {
  int plugin_id = -1;
  const metasonic::PluginSpec *spec = nullptr;

  // §6.E v2: host-owned per-instance plugin state. Zeroed at
  // instance reset. spec->init is *not* called in v2 — see §4
  // opening paragraph. spec->process gets &storage[0] each block,
  // or nullptr if state_size_bytes == 0 so the Identity path
  // stays bit-equivalent to v1.
  //
  // metasonic:: qualifier matches the existing PluginSpec / plugin_at
  // usage at rt_graph.cpp:1845 / 5621 — kMaxPluginState lives in
  // rt_graph_plugins.h inside `namespace metasonic`, and rt_graph.cpp
  // does not `using namespace metasonic`.
  alignas(std::max_align_t)
  std::array<std::byte, metasonic::kMaxPluginState> storage{};
};
```

The `std::byte` and `std::max_align_t` types both require `<cstddef>`.
`rt_graph.cpp` already includes `<array>` for `std::array` (line 34)
but `<cstddef>` is not currently pulled in directly. Add it
alongside the existing `<array>` include — see §7 site 11a.

### 4.1a What `alignas(std::max_align_t)` actually buys (and what it does not)

`alignas(std::max_align_t)` guarantees the storage is aligned for
any scalar type up to native alignment, so a `reinterpret_cast`
from `storage.data()` to (say) `float *` does not produce a
misaligned access. **It does not, on its own, make the buffer
contain a legitimate C++ object that the plugin may read or write.**
The C++ object model requires either an explicit construction step
(placement-new) or an *implicit-lifetime* type
([P0593R6](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0593r6.html),
C++20) for an object to come into existence in raw `std::byte`
storage. Reading the buffer as a type whose lifetime never began
is undefined behavior, regardless of alignment.

v2 explicitly does **not** call `spec->init` from anywhere (see §4
opening). It also does not call placement-new on the storage from
the host. The only way the storage is well-defined for plugin use
without those is if v2 pins this contract on plugin state:

- **Plugin state must be zero-valid.** An all-zeros byte pattern
  must be a meaningful initial value the plugin can read and write
  through. Plugins with a `0xFF`-initialized cache, an enum-tagged
  variant whose zero discriminator is invalid, or anything that
  needs a constructor cannot ship in v2.
- **Plugin state must be implicit-lifetime / trivially copyable.**
  Concretely: scalar types, arrays/aggregates of scalar or
  implicit-lifetime types, and trivially-copyable user types
  (no user-provided constructors / destructors, no virtual
  members). Plugins that need a non-trivial constructor or
  destructor are blocked on the init-seam follow-up (§9 Q-4),
  because that is what `spec->init` and placement-new are for.

The one-tap delay's state is a single `float`:

```cpp
namespace {
struct OneTapDelayState { float prev_sum = 0.0f; };
}
```

`float` is a scalar (and therefore implicit-lifetime + trivially
copyable), its zero pattern is the well-defined initial state
(`prev_sum = 0.0f`), and `alignof(float) = 4 <= alignof(std::max_align_t)`,
so reinterpreting `storage.data()` as `OneTapDelayState *` and
reading / writing `prev_sum` is well-defined in v2's no-`init`
world. Any future plugin that does not fit this contract is the
forcing function the init-seam follow-up §9 Q-4 names.

`kMaxPluginState = 4096` is the v1 §2.1 design constant; both
shipped plugins use ≤ 4 bytes, and the constant is intentionally
oversized to absorb the next several zero-valid plugins without
changes.

**Variant-footprint observation, pinned explicitly.** `StaticPluginState`
lives inside the `NodeState` variant at
[rt_graph.cpp:885-901](../tinysynth/rt_graph.cpp). The variant's
sizeof is the max over its alternatives. The size-driver today is
`SpectralFreezeState`: `StftRings` alone is `kN + (kN+kHop) + 2*kN`
floats = `(1024 + 1280 + 2048) * 4 ≈ 17 KiB`, plus the
freeze-specific `frozen_spectrum` Hermitian half
`(kN/2 + 1) * sizeof(complex)` ≈ 4 KiB, plus `frozen_valid` and
the shared ring heads/counters. The full variant arm is on the
order of **~21 KiB per node**. `SpectralLpfState` is the same
order minus the freeze-specific 4 KiB.

A 4096-byte `storage[]` on `StaticPluginState` is therefore
**free-riding** on the spectral arms — adding it does not grow
`sizeof(NodeState)` because spectral states already dominate. Every
node in every instance already pays the spectral size cost.

This is a fragile invariant. If a future cleanup moves spectral
state out-of-line (heap-owned, pointer in the variant arm,
producer-allocated at template-load time), the plugin `storage[]`
becomes the new size-driver, and a 4 KiB-per-node cost across an
entire instance becomes visible. The right response when that
happens is the same response spectral state would have taken:
move plugin state out-of-line too, allocated at
producer-side `init_node_state` time based on each plugin's
declared `state_size_bytes`, with a pointer on the variant arm.
Out-of-line allocation also dissolves the `kMaxPluginState` cap.
**Do not do this work in v2** — it is exactly the broader
follow-up [§6.E Q-1](2026-05-11-h-phase-6e-plugin-hosting-design.md)
parked, and v2's free-ride lets us defer it until either spectral
states change shape or a plugin actually needs more than 4 KiB.
But pin the dependency in code as a static_assert in the same TU
as `StaticPluginState`:

```cpp
// §6.E v2 invariant: StaticPluginState's inline blob free-rides on
// the spectral states' variant footprint. If this assertion ever
// fires, plugin storage has become the NodeState size-driver and
// the contract in notes/2026-05-19-d §4.1 requires either
// shrinking kMaxPluginState or moving plugin state out-of-line.
static_assert(
    sizeof(StaticPluginState) <= sizeof(SpectralFreezeState),
    "StaticPluginState must not grow the NodeState variant past the "
    "spectral arms; see notes/2026-05-19-d-phase-6e4-second-static-plugin-contract.md §4.1");
```

That assertion is what makes the free-ride explicit and turns a
future spectral-state diet into a compile-time failure that
forces the contract conversation rather than silently doubling
every instance's footprint.

### 4.2 `register_plugin` enforces the size bound

`register_plugin` in
[tinysynth/rt_graph_plugins.cpp:27-36](../tinysynth/rt_graph_plugins.cpp)
currently rejects on null spec / null name, count overflow, and
duplicate name. Add: reject (return `-1`) if
`spec->state_size_bytes < 0 || spec->state_size_bytes > kMaxPluginState`.
The v1 design explicitly placed the upper-bound check at
registration time
([§6.E §2.1](2026-05-11-h-phase-6e-plugin-hosting-design.md));
the lower-bound check is the same line of defense: `state_size_bytes`
is a signed `int` on `PluginSpec`
([tinysynth/rt_graph_plugins.h:7](../tinysynth/rt_graph_plugins.h))
and a negative value would silently take the
zero-state-pass-`nullptr` branch in §4.4 (treating an invalid
plugin as if it correctly declared `state_size_bytes = 0`), masking
the metadata error. Both bounds reject at registration so the
runtime registry never carries an out-of-spec row.

### 4.3 `init_node_state` zero-initializes only

The `case NodeKind::StaticPlugin` arm in `init_node_state`
([tinysynth/rt_graph.cpp:1837-1856](../tinysynth/rt_graph.cpp))
keeps its current shape: resolve `plugin_id` and `spec`, construct
`StaticPluginState{plugin_id, plugin_spec}`. The `storage[]` array
is value-initialized to zero by `std::array<std::byte>{}`.
**`spec->init` is not called here, or anywhere in v2.**

This preserves the existing invariants on both sides: `init_node_state`
continues to do no audio-thread-coupled work and reads nothing from
`RTGraph`; the v1 hosting contract's claim that `init` runs on the
producer thread is not contradicted because v2 never calls it.
Identity's audio-thread behavior stays bit-equivalent to v1:
Identity's `init` body was empty in v1 and remains uncalled in v2.

### 4.4 `process_static_plugin` passes a non-null state pointer

The dispatcher in
[tinysynth/rt_graph.cpp:5603-5658](../tinysynth/rt_graph.cpp)
currently always passes `state = nullptr`. The v2 change is a
single branch on `spec->state_size_bytes`:

```cpp
auto *st = std::get_if<StaticPluginState>(&node.state);
if (st == nullptr || st->spec == nullptr || st->spec->process == nullptr
    || st->spec->audio_in_count != 2 || st->spec->audio_out_count != 1) {
  std::fill(out.begin(), out.end(), 0.0f);
  return;
}

// ... existing input resolution unchanged ...

// Identity (state_size_bytes = 0) keeps a nullptr state pointer.
// Stateful plugins get the zero-initialized inline blob. spec->init
// is intentionally never called in v2 — see §4 opening paragraph.
// A plugin whose correct initial state is anything other than
// all-zeros cannot ship until the init-seam follow-up lands.
void *state_ptr =
    (st->spec->state_size_bytes > 0) ? st->storage.data() : nullptr;
const int rc =
    st->spec->process(state_ptr, nframes, inputs, outputs);
```

Counter contract is unchanged: `++g.plugin_call_count` regardless
of return code, `++g.invalid_plugin_call_count` on non-zero return.

One-tap-delay's initial state (`prev_sum = 0.0f`) is exactly the
zero-initialized blob, so the missing `init` call costs nothing
observable. Any future stateful plugin whose correct initial state
is not all-zeros (a filter with a non-zero coefficient cache, a
delay line whose ring head needs a non-zero offset, anything reading
`sample_rate` at construction) is blocked on the init-seam
follow-up §4 names — that is by design.

Counter-confirmed validation applies: the existing "identity
output is bit-exact to a hand-rolled add graph" test plus
`plugin_call_count` ticks together prove the Identity path still
runs and still produces the same samples after the state-pointer
branch is introduced.

### 4.5 Sample rate and max-frames sourcing

Not used by v2. `g.sample_rate` and `g.max_frames` are not consumed
by any plugin in this slice because no `spec->init` call site
exists. The init-seam follow-up note will decide which seam
sources them (producer-thread `init_node_state` via reshaped
signature, or RT-safe-by-contract `init` from
`process_static_plugin`); pinning the answer here would commit to
that contract ahead of the second user that motivates it. Both
values stay reachable through `RTGraph` whichever way the seam
lands.

### What stays per-kind

- The variant-on-state model in
  [rt_graph.cpp:885-901](../tinysynth/rt_graph.cpp) is unchanged;
  `StaticPluginState` is still one of the variant arms (with the
  free-ride invariant above).
- `node_kind_supports_state_migration KStaticPlugin = false`
  ([rt_graph.cpp:2946-2950](../tinysynth/rt_graph.cpp)) stays. The
  v1 contract pinned no migration for static plugins until per-plugin
  opt-in is designed ([§6.E Q-2](2026-05-11-h-phase-6e-plugin-hosting-design.md));
  a stateful row does not relax that.
- `KStaticPlugin` stays scheduler-opaque (no Barrier predicate, no
  region-formation special-case) — same as v1.

## 5. Tests

Counter-confirmed-validation discipline (the discipline shared
with the §6.C buffer-kind series and the §6.D spectral series:
when a test swaps in a new execution path, assert against a
counter that proves the path actually ran, not just that the
output is byte-equivalent — a path swap producing correct-by-luck
output is exactly what the counter pairs catch). Reuse the
existing `plugin_call_count` / `invalid_plugin_call_count`
counters; no new counter pair this slice. Tests go in
`oneTapDelayPluginTests`, a new group in
[test/MetaSonic/Spec/Feature/StaticPlugin.hs](../test/MetaSonic/Spec/Feature/StaticPlugin.hs)
parallel to `staticPluginSkeletonTests`.

1. **Haskell catalog row** —
   `staticPluginCatalog` includes a `oneTapDelayPlugin` row with
   `spiPluginId = 1`, `spiAudioInputs = 2`, `spiAudioOutputs = 1`,
   `spiLatencySamples = 1`, `spiEffects = [Pure]`,
   `spiLabel = "one-tap-delay"`.
   `staticPluginInfo oneTapDelayPlugin` returns that row.
   `staticPluginId oneTapDelayPlugin == Just 1`.
   `staticPluginInfoById 1` returns the row;
   `staticPluginInfoById 0` returns Identity.
2. **`inferEff` for one-tap-delay yields `[Pure]`** — a graph
   carrying one-tap-delay produces a `Pure` effect entry on the
   plugin node, same shape as the existing Identity test.
3. **Runtime registry agreement** — `pluginRegistryEntries`
   contains exactly one `"one-tap-delay"` row whose
   `pluginEntryAudioInputs`, `pluginEntryAudioOutputs`,
   `pluginEntryLatencySamples`, `pluginEntryStateBytes`
   all agree with the Haskell `StaticPluginInfo` row. Mirrors the
   existing Identity registry-agreement test.
4. **`nodeDeclaredLatency` resolves through the catalog** —
   compile a one-template graph with `staticPlugin
   oneTapDelayPlugin a b`; assert that the resulting `RuntimeNode`
   for that plugin has `nodeDeclaredLatency n == Just 1`. The
   companion Identity case asserts **`Nothing`** (Identity's
   `spiLatencySamples = 0`, and §3's accessor preserves the
   `kindLatency` invariant that zero latency is reported as
   `Nothing`, not `Just 0` — pinning this in the test catches a
   future regression where the accessor starts leaking `Just 0`).
4a. **`finitePluginId` and `nodeDeclaredLatency` reject malformed
    plugin_id values** — exhaustive table:
    `finitePluginId 0`, `finitePluginId 1` resolve;
    `finitePluginId (0/0)` (NaN),
    `finitePluginId (1/0)` (+Inf),
    `finitePluginId (-1/0)` (-Inf),
    `finitePluginId (-1)` (negative),
    `finitePluginId 0.5` (non-integral),
    `finitePluginId 1.5` (non-integral),
    `finitePluginId 1e100` (overflows Int via `round`),
    `finitePluginId (2 ** 53)` (the exclusive upper bound — at
    exactly 2^53 the gap between adjacent Doubles is 1.0, so
    everything from this point up is rejected),
    `finitePluginId (2 ** 54)` (a representable Double clearly
    above the bound — written as `2 ** 54` not
    `2 ** 53 + 1` because the latter silently rounds back to
    `2 ** 53` in Double and would not actually exercise the
    out-of-range path)
    all return `Nothing`. A companion accept case pins the
    boundary as exclusive on the high side, but derives the test
    value from `maxExactPluginId` rather than hard-coding
    `2 ** 53 - 1`. The §3 definition clamps with
    `min (2 ** 53) (fromIntegral (maxBound :: Int))` so a
    hypothetical 32-bit `Int` target stays safe; a literal
    `2 ** 53 - 1` accept case would fail on such a target for the
    wrong reason. `maxExactPluginId` is exported from
    `MetaSonic.Bridge.Source` as a module-level binding (see §3 +
    site 3), so the test imports the same constant the parser
    consults:

    ```haskell
    import MetaSonic.Bridge.Source (finitePluginId, maxExactPluginId)

    let boundary = round maxExactPluginId - 1 :: Int
    finitePluginId (fromIntegral boundary) @?= Just boundary
    ```

    On every supported target today (64-bit `Int`), `boundary`
    evaluates to `2^53 - 1` and the assertion exercises the
    intended high-side accept. On the hypothetical 32-bit target,
    it collapses to `(maxBound :: Int) - 1` and the assertion is
    still well-defined. The reject cases (`2 ** 53` and `2 ** 54`)
    are correct on any target where `maxExactPluginId <= 2 ** 53`,
    so they stay as literals — at worst they're rejected for being
    above an even smaller bound on a 32-bit target, which is still
    the intended behavior. Companion negative cases: a `RuntimeNode` whose
    `rnControls = []` returns `nodeDeclaredLatency n == Nothing`
    (catches an empty-controls regression that would otherwise
    crash `head` / `(!! 0)`); a `RuntimeNode` whose first control
    is `0/0` returns `Nothing` (rather than crashing on
    `round NaN`); a `RuntimeNode` whose first control is `1e100`
    returns `Nothing` (rather than producing
    implementation-defined `Int` nonsense from `round`).
    Construct these `RuntimeNode` values directly in the test
    rather than going through `compileTemplateGraph`, so the test
    pins the accessor's behavior on inputs the compiler would
    never legitimately produce. This is the test that catches both
    the old crash-prone `round pidD` sketch and the silent-overflow
    follow-up.
5. **`declaredLatencyFootprint` includes the one-tap row** —
   compile the same graph; assert the footprint contains a
   `DeclaredNodeLatency` with `dnlKind = KStaticPlugin` and
   `dnlLatency = 1`. The corresponding test for an
   Identity-only graph asserts an *empty* footprint (Identity's
   `spiLatencySamples = 0` makes `nodeDeclaredLatency` return
   `Nothing`, regardless of the downstream `lat > 0` belt-and-
   suspenders filter).
5a. **`fcfLatencyNodes` / `fcfMaxLatency` count the one-tap row** —
    run `FusionCostLab.extractFeatures` on a region containing the
    one-tap-delay plugin and assert `fcfLatencyNodes == 1` and
    `fcfMaxLatency == 1`. The same test against an Identity-only
    region asserts `fcfLatencyNodes == 0` and `fcfMaxLatency == 0`.
    Without the §3 migration of
    [FusionCostLab.hs:548](../app/MetaSonic/App/FusionCostLab.hs)
    this test would fail (plugin invisible to the cost-lab feature
    row even when visible to the survey), which is the regression
    the migration prevents.

    **Test-module placement:** this assertion goes in a new
    `MetaSonic.Spec.AppFusionCostLab` module under `test/`, not in
    `MetaSonic.Spec.Feature.StaticPlugin`. The test component's
    [package.yaml](../package.yaml) `other-modules` list does not
    currently include `MetaSonic.App.FusionCostLab` or
    `MetaSonic.App.FusionCostModel` (only the *executable*
    component lists them at
    [package.yaml:159-160](../package.yaml)), so an import of
    `MetaSonic.App.FusionCostLab` from `Feature/StaticPlugin.hs`
    would fail to resolve. The new `AppFusionCostLab` test module
    sits alongside the existing `AppManifest*` test modules and
    is wired in by listing both `MetaSonic.App.FusionCostLab` and
    `MetaSonic.App.FusionCostModel` in the test component's
    `other-modules` (see §7 site 17a). This mirrors the
    `AppManifestReloadCli` / `AppManifestOSCListener` /
    `AppManifestMIDIListener` pattern already in the tree:
    app-level assertions live in their own
    `MetaSonic.Spec.App<Module>` test module.
6. **`plugin_call_count` ticks once per block** — render N blocks
   of a one-tap-delay graph; assert `plugin_call_count == N`,
   `invalid_plugin_call_count == 0`. Identical shape to the
   existing Identity counter-math test.
7. **Output delay is exactly 1 sample across the block-0
   boundary** — drive `in0` from `playBufMono` reading a
   16-frame buffer loaded with an impulse at frame 3
   (`[0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0]`); wire `in1` as
   `Param 0.0` (so the kernel sees `b == nullptr` and treats it
   as zero per §2's null-as-zero contract), `nframes = 16`.
   Render one block.
   Assert `out[0..3] == 0`, `out[4] == 1.0f`, and
   `out[5..] == 0`. This is the strongest possible single-block
   assertion of the 1-sample-delay contract. The
   `playBufMono`-from-loaded-buffer pattern is the only way the
   DSL can express a one-shot time-positioned signal without
   adding a new generator UGen or a new C++ test-only injection
   helper — the FFI loader at
   [FFI.hs:2222](../src/MetaSonic/Bridge/FFI.hs) wires only
   `RFrom` inputs and skips `RConst`, so there is no public ABI
   for writing into an `in0` buffer span directly. This is the
   same idiom the §6.D `playBufMono`-driven impulse test uses
   in [PatternOSCBuffer.hs:2355-2402](../test/MetaSonic/Spec/PatternOSCBuffer.hs).
8. **Output delay carries across block boundaries** — same
   `playBufMono`-driven setup as #7 but with the impulse at the
   *last* sample of a buffer sized to cover both blocks
   (e.g. a 128-frame buffer with the impulse at frame 63 and
   zeros everywhere else), `in1` still wired as `Param 0.0`,
   `nframes = 64`. Render block 0, then block 1; `playBufMono`
   continues reading frames 64-127 (all zero) so `in0` is
   effectively `0` across block 1 by construction. Assert block 0's
   output is all zero; assert block 1's `out[0] == 1.0f` and the
   rest zero. This is the test that catches a per-block reset
   (state not persisted across the block boundary).
8a. **Null-as-zero handling** — render a one-tap graph where
    **both** inputs are `Param 0.0` (so `process` receives
    `inputs[0] == nullptr && inputs[1] == nullptr`). Assert the
    output is all zero and `plugin_call_count` ticks normally
    (no `invalid_plugin_call_count` ticks). This pins the
    §2 null-input contract directly and catches the regression
    where one-tap-delay forgets to mirror Identity's null guard
    and dereferences `nullptr` instead.
9. **Independent state across two plugin nodes in the same
   template (last-sample carry leak check)** — allocate two
   buffers of size `nframes`. Load buffer A with an impulse at
   the **last** sample (`buffer_A[nframes-1] = 1`, zeros
   elsewhere); load buffer B with all zeros (silent peer).
   Build a graph with two `staticPlugin oneTapDelayPlugin` nodes
   in topological order — plugin α fed by `playBufMono`(buffer A)
   + `Param 0.0`, plugin β fed by `playBufMono`(buffer B) +
   `Param 0.0` — written to **separate output buses**: plugin α
   → `busOut 0`, plugin β → `busOut 1`. Render one block, then
   read both buses. Per-instance storage produces bus 0 and bus 1
   both all-zero (plugin α stores its impulse into its own
   `prev_sum` but no sample of block 0 emits it; plugin β never
   sees an impulse). A shared-storage implementation puts
   `prev_sum` on `PluginSpec` (or any other location keyed on
   plugin id rather than instance + node), in which case plugin α
   writes `prev_sum = 1` *during block 0* and plugin β reads that
   `prev_sum = 1` on its first sample, emitting
   `bus 1 = [1, 0, ..., 0]`. **Assert `bus 1 == [0,...,0]` for
   block 0.** That assertion is what catches a leak; the original
   "different impulse offsets summed before `out 0`" framing did
   not catch it, because both plugins land on `prev_sum = 0` at
   the end of a block whose impulse is mid-block, so a
   shared-storage implementation would have passed.
   Counter-confirmed by `plugin_call_count == 2 * nblocks`.
10. **Independent state across two voices of the same template
    (last-sample carry leak check)** — define a single template:
    `pa` = `playBufMono` reading buffer 0 with default
    `start_frame = 0`, `da` = `staticPlugin oneTapDelayPlugin pa
    (Param 0.0)`, `bo` = `busOut da` with default bus index `0`.
    Both voices read the same source — per-instance `start_frame`
    overrides are not implementable (the playBufMono kernel seeds
    `playhead_pos` from `controls[2]` once at instance reset in
    [rt_graph.cpp:1775-1776](../tinysynth/rt_graph.cpp); subsequent
    reads of port 1 are `PortIgnored`, and
    `instance_set_control` only mutates `node.controls[2]`
    at [rt_graph.cpp:6601](../tinysynth/rt_graph.cpp) without
    rewinding the seeded playhead). Per-voice differentiation
    comes from **per-instance bus routing** instead.

    Load buffer 0 with an impulse at the **last sample**
    (`buffer_0[nframes-1] = 1`, zeros elsewhere). **Use
    `loadTemplateGraphWithAutoSpawns`, not `loadTemplateGraph`.**
    The default loader at
    [FFI.hs:2409-2413 / 2475-2479](../src/MetaSonic/Bridge/FFI.hs)
    spawns one instance per template ("the typical single-voice
    ensemble case"); discarding that slot id with the plain
    `loadTemplateGraph` and then `realtime_reserve`-ing two more
    would yield **three** active voices, contaminate the
    `plugin_call_count == 2 * nblocks` assertion (it would be
    `3 * nblocks`), and corrupt the shared-storage leak check
    because the auto-spawned voice runs before any reserved
    voice. The instrumented loader returns `[(template_id,
    slot_id)]`; the test:

    1. Calls `loadTemplateGraphWithAutoSpawns g tg` and captures
       the returned `[(0, autoSlot)]`.
    2. Calls `c_rt_graph_instance_remove g autoSlot` to retire
       that voice before any audio runs through it.
    3. Pre-warms the template's slot pool to at least two
       `Available` slots — `realtime_reserve` never grows the
       pool per
       [FFI.hs:1341-1345](../src/MetaSonic/Bridge/FFI.hs).
    4. `realtime_reserve` twice to get voice A and voice B
       handles.
    5. Immediately after each reserve, overrides `busOut`'s
       `controls[0]` per-instance via
       `c_rt_graph_instance_set_control`: voice A → bus 0,
       voice B → bus 1.
    6. `realtime_activate` for both.

    Render block 0 and read both buses. With per-instance
    `StaticPluginState`, voice A and voice B each maintain their
    own `prev_sum`: both write `prev_sum = 1` at the end of block
    0 but neither emits the carried sample yet, so
    `bus 0 == [0,...,0]` and `bus 1 == [0,...,0]`. With shared
    storage on `PluginSpec`, voice A processes first and writes
    the shared `prev_sum = 1`; voice B then reads that
    `prev_sum = 1` and emits `bus 1 = [1, 0, ..., 0]`.
    **Assert `bus 0 == [0,...,0]` AND `bus 1 == [0,...,0]` for
    block 0.** The leak is in bus 1; bus 0 is asserted for
    symmetry so a future bug that reorders voice dispatch is
    still caught.

    Counter-confirmed by `plugin_call_count == 2 * nblocks` (one
    tick per process dispatch, summed over the two live test
    instances; the auto-spawn was removed in step 2). This
    catches the `storage`-on-`PluginSpec` bug; the previous
    "different start_frame per voice" framing was not
    implementable against the current PlayBufMono control
    semantics.
11. **Identity and one-tap-delay coexist on the same graph** —
    one template carrying both `staticPlugin identityPlugin`
    (driven by two `sinOsc` sources, as in the existing Identity
    bit-exact test) and `staticPlugin oneTapDelayPlugin` (driven
    by a `playBufMono` impulse on `in0` and `Param 0.0` on `in1`)
    on disjoint voices, written to separate output buses
    (`out 0` for Identity, `out 1` for one-tap). Render N blocks.
    Assert: bus 0 has the expected Identity sum (bit-exact
    against the existing hand-rolled `add` graph render); bus 1
    has the expected one-tap-delayed impulse pattern. Counter:
    `plugin_call_count == 2 * N` (one tick per plugin instance
    per block). This is the test that catches the dispatcher
    picking the wrong vtable for one of the two plugin ids — a
    bug a single-plugin test could not surface.
12. **`kindLatency KStaticPlugin` stays `Nothing`, and
    `kindCapabilities` stays `[CapHardBarrier]`** — explicit
    rows in the test, to pin that this slice did not silently
    flip the kind-level metadata. Mirrors §3's design contract.
13. **`register_plugin` rejects out-of-range `state_size_bytes`
    (C++ test, mandatory)** —
    `tinysynth_tests` already links `tinysynth_rt`
    ([CMakeLists.txt:105](../CMakeLists.txt)) and the doctest
    framework is already in place
    ([CMakeLists.txt:88-110](../CMakeLists.txt)), so the only
    honest test of "invalid specs are rejected at registration
    time" lives on the C++ side and **must** ship in
    `tests/rt_graph_test.cpp` (see §7 site 17c). Four cases,
    asserting `metasonic::register_plugin(&spec)` returns `-1`
    for the rejections and a valid `>= 0` plugin id for the
    accept case:

    - `state_size_bytes = metasonic::kMaxPluginState + 1`
      (upper bound, just past).
    - `state_size_bytes = -1` (negative — catches the silent
      take-the-zero-state-branch failure mode flagged in §4.2).
    - `state_size_bytes = INT_MIN` (extreme negative, catches
      any signed-arithmetic regression that flips the comparison).
    - `state_size_bytes = metasonic::kMaxPluginState` (boundary
      accept case) pins the inclusive upper bound.

    A Haskell-side smoke that parses the runtime registry and
    asserts every shipped row's `pluginEntryStateBytes` lies in
    `[0, kMaxPluginState]` is **not** an acceptable substitute:
    a registry smoke only proves the rows that did register are
    in range, not that invalid specs would have been rejected.
    The check needs to attempt a registration that should fail
    and observe the rejection, which only the C++ test surface
    can do.

Counter-confirmed-validation reminder: tests 6 / 9 / 10 / 11 all
use `plugin_call_count` not just to check audio equivalence. The
counter proves the new dispatch path actually ran the kernel; a
bit-equivalence-only test could be silently satisfied by leftover
silence from an old code path.

Expected new test count: ~16 §5 cases total (13 numbered
#1-#13 plus the three sub-numbered 4a / 5a / 8a additions
added against the original draft), split across three sites:

- `StaticPlugin.hs` picks up cases 1, 2, 3, 4, 4a, 5, 6, 7, 8,
  8a, 9, 10, 11, 12 — 14 new cases. The existing total in
  [StaticPlugin.hs](../test/MetaSonic/Spec/Feature/StaticPlugin.hs)
  is 9 cases (verify by grepping `testCase` in that file);
  the file grows to 23.
- `MetaSonic.Spec.AppFusionCostLab` (new test module, site 17a)
  picks up case 5a — 1 new case.
- `tests/rt_graph_test.cpp` (existing C++ doctest TU, site 17c)
  picks up case 13 — 1 new doctest, mandatory per the §5 #13
  rewrite.

Total Haskell test growth: 15 new cases (14 in `StaticPlugin.hs`
+ 1 in `AppFusionCostLab`).

## 6. Corpus / survey

No new corpus row, no new pattern shape, no new
`--corpus-survey` / `--fusion-survey` plumbing.

Rationale:

- The §6.D second-spectral-kind contract
  ([§6 of 2026-05-19-c](2026-05-19-c-phase-6d-second-spectral-kind-contract.md))
  recommended *one* second template inside the existing
  `spectral-freeze-pad` row, on the grounds that the row's purpose
  was "provide the only non-trivial declared-latency surface for
  the survey." That argument no longer applies in the same form
  for plugins: there is no pre-existing plugin pattern corpus row
  to extend.
- Adding a pattern corpus row for a non-musical "two-input one-
  sample delayed sum" plugin would be pure ceremony — there is no
  musical pattern shape the row would represent, and the
  declared-latency surface is already exercised by tests #4 / #5
  in §5 above on a hand-built graph.
- Surfacing one-tap-delay in `--fusion-survey`'s declared-latency
  footprint is the natural reporting surface, but
  `declaredLatencyFootprint` is already consumed by the survey
  printer; the §3 accessor migration makes the row appear
  automatically *for any plugin-graph the survey already runs*.
  No new survey wiring needed.

If a follow-up wants a plugin-specific corpus row (e.g. a
`plugin-bed` row carrying a stable mini-graph with both Identity
and one-tap-delay), that is its own slice with its own design
note. Out of scope here.

## 7. Sites

This is **not** a new kind — `KStaticPlugin` stays. The sites
table reflects only the rows that actually need editing for the
second catalog row + the host-owned-state seam. No `kindSpec` /
`kindLatency` /
`kindCapabilities` / `portInfo` row for `KStaticPlugin` changes.

| #  | File                                          | Edit                                                                                                                                              |
|----|-----------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | `src/MetaSonic/Bridge/Source.hs`              | Add `oneTapDelayPlugin :: PluginRef` next to `identityPlugin`                                                                                     |
| 2  | `src/MetaSonic/Bridge/Source.hs`              | Add second row to `staticPluginCatalog` (id 1, arity 2 → 1, latency 1, `[Pure]`, label `"one-tap-delay"`)                                          |
| 3  | `src/MetaSonic/Bridge/Source.hs`              | Add `staticPluginInfoById :: Int -> Maybe StaticPluginInfo`, `finitePluginId :: Double -> Maybe Int`, and the module-level binding `maxExactPluginId :: Double`; export all three. The `maxExactPluginId` lift (rather than the original `where` binding) is what lets the §5 #4a accept-boundary test reference the same constant the parser uses |
| 4  | `src/MetaSonic/Bridge/Compile/Latency.hs`     | Add `nodeDeclaredLatency :: RuntimeNode -> Maybe Int` (consults catalog via `finitePluginId` + `staticPluginInfoById` for `KStaticPlugin`, returns `Nothing` for zero latency to preserve the `kindLatency` invariant, falls back to `kindLatency` for every other kind); export it |
| 5  | `src/MetaSonic/Bridge/Compile/Latency.hs`     | Migrate `declaredLatencyFootprint` and `nodeOutputLatencies` from `kindLatency (rnKind n)` to `nodeDeclaredLatency n`                              |
| 6  | `app/MetaSonic/App/FusionCostLab.hs`          | Migrate the `latencies = [ ... kindLatency (rnKind n) ... ]` line at [FusionCostLab.hs:548](../app/MetaSonic/App/FusionCostLab.hs) to `nodeDeclaredLatency n`; import `nodeDeclaredLatency` from `Compile.Latency` (the existing `kindLatency` import at [FusionCostLab.hs:130](../app/MetaSonic/App/FusionCostLab.hs) drops if no other call site remains) |
| 6a | `app/MetaSonic/App/Survey.hs`                 | Refresh the header line at [Survey.hs:2209](../app/MetaSonic/App/Survey.hs) — `"kindLatency-bearing nodes"` is no longer true once `KStaticPlugin` one-tap rows enter the footprint via `nodeDeclaredLatency`. Replace with `"declared per node"` or equivalent (the §3 "User-facing wording" paragraph above pins the principle; exact wording is implementation-slice choice) |
| 6b | `src/MetaSonic/Bridge/Compile/Latency.hs`     | Refresh the module header comment at [Compile/Latency.hs:9-12](../src/MetaSonic/Bridge/Compile/Latency.hs) — `"It consumes the existing 'kindLatency' metadata"` is no longer accurate. Update to reference `nodeDeclaredLatency` and note that the per-instance plugin path is also consulted                                                  |
| 7  | `tinysynth/plugins/one_tap_delay.cpp` (new)   | `OneTapDelayState`, `one_tap_delay_init` / `_reset` / `_process`, `kOneTapDelaySpec`, `one_tap_delay_plugin_spec()` (mirrors `identity.cpp`)      |
| 8  | `tinysynth/rt_graph_plugins.cpp`              | Forward-declare `one_tap_delay_plugin_spec()`; register it inside `ensure_builtin_plugins_registered` after Identity                              |
| 9  | `tinysynth/rt_graph_plugins.cpp`              | Add `state_size_bytes` bound check to `register_plugin` (`spec->state_size_bytes < 0 \|\| spec->state_size_bytes > kMaxPluginState` → return `-1`) |
| 10 | `tinysynth/rt_graph_plugins.h`                | Declare `constexpr int kMaxPluginState = 4096` inside `namespace metasonic`. **Must be in the header**, not in `rt_graph_plugins.cpp`'s anonymous namespace — `tests/rt_graph_test.cpp` (site 17c) references `metasonic::kMaxPluginState` directly in the §5 test #13 doctest cases, so the constant has to be visible at every translation unit that links against `tinysynth_rt`                                  |
| 11 | `tinysynth/rt_graph.cpp`                      | `StaticPluginState`: add `alignas(std::max_align_t) std::array<std::byte, metasonic::kMaxPluginState> storage{}`. **No `bool initialized` field** — v2 never calls `spec->init`, so the latch is not needed; revisit when the init-seam follow-up lands. **Note `metasonic::` qualifier** — the constant lives in `rt_graph_plugins.h` inside `namespace metasonic` (see §4.1), and `rt_graph.cpp` does not `using namespace metasonic` (see existing qualified uses at [rt_graph.cpp:1845 / 5621](../tinysynth/rt_graph.cpp)) |
| 11a| `tinysynth/rt_graph.cpp`                      | Add `#include <cstddef>` alongside the existing `<array>` include (around [rt_graph.cpp:34](../tinysynth/rt_graph.cpp)). `std::byte` and `std::max_align_t` both live there and `rt_graph.cpp` does not currently include it directly                                                                                                                                                                                |
| 12 | `tinysynth/rt_graph.cpp`                      | Add the `static_assert(sizeof(StaticPluginState) <= sizeof(SpectralFreezeState), ...)` from §4.1 immediately after `StaticPluginState`'s definition |
| 13 | `tinysynth/rt_graph.cpp`                      | `init_node_state` `KStaticPlugin` arm: **no behavioral change** — continues to zero-initialize storage and does **not** call `init` (v2 never calls `init` anywhere; see §4 opening and §4.3)                                                |
| 14 | `tinysynth/rt_graph.cpp`                      | `process_static_plugin`: pass `st->storage.data()` to `spec->process` when `state_size_bytes > 0`; keep `nullptr` for zero-state plugins (Identity). **No `init` call** — v2 never calls `spec->init` anywhere; the init-seam follow-up §4 defers picks producer-thread vs RT-safe-by-contract|
| 15 | `package.yaml`                                | Add `tinysynth/plugins/one_tap_delay.cpp` to `cxx-sources` after the existing identity entry                                                       |
| 16 | `CMakeLists.txt`                              | Add `tinysynth/plugins/one_tap_delay.cpp` to `tinysynth_rt` after the existing identity entry                                                      |
| 17 | `test/MetaSonic/Spec/Feature/StaticPlugin.hs` | Add `oneTapDelayPluginTests` group with the §5 cases **except 5a (lives in `AppFusionCostLab`, site 17a) and #13 (lives in `tests/rt_graph_test.cpp`, site 17c)** — so this group ships the 14 cases 1, 2, 3, 4, 4a, 5, 6, 7, 8, 8a, 9, 10, 11, 12; wire into `Spec.hs` |
| 17a| `test/MetaSonic/Spec/AppFusionCostLab.hs` (new) | Add `appFusionCostLabTests` group containing test 5a; wire into `Spec.hs`. New module is required because `MetaSonic.App.FusionCostLab` does not resolve from `Feature/StaticPlugin.hs` (see §5 test 5a placement note) |
| 17b| `package.yaml`                                | Test component `other-modules`: add `MetaSonic.App.FusionCostLab`, `MetaSonic.App.FusionCostModel`, and `MetaSonic.Spec.AppFusionCostLab`. The first two are already wired in the *executable* `other-modules` at [package.yaml:159-160](../package.yaml) but the test component does not currently see them                                                                                              |
| 17c| `tests/rt_graph_test.cpp` (existing)          | Add the §5 test #13 cases (negative / boundary / over-bound `state_size_bytes`) as doctest cases. The C++ test target is mandatory per §5 test #13's rewritten contract — no Haskell fallback                                                                                                                                                                                                            |

Note that sites 15 and 16 must stay in lockstep — `cxx-sources` in
`package.yaml` and the `add_library(tinysynth_rt STATIC ...)` list
in `CMakeLists.txt` are two independent build paths (Haskell via
hpack-generated cabal + cxx-sources; the standalone CMake build
that produces `build-cpp/` plus `compile_commands.json` for
clangd, `rt_graph_smoke`, and `tinysynth_tests`). Updating one
without the other is silent drift — both must list every
`tinysynth/**/*.cpp` source file.

After sites 17 / 17a / 17b / 17c land and the
`kindSpec / portInfo` agreement QuickCheck property in
[test/Spec.hs](../test/Spec.hs) still passes (it must — no kind
metadata changed), the slice is implementable in one commit if
small, or two if the C++ inline-blob plumbing
(sites 7 / 8 / 9 / 10 / 11 / 11a / 12 / 13 / 14 / 15 / 16 / 17c)
lands in its own commit before the catalog row + Haskell
consumer migrations
(sites 1 / 2 / 3 / 4 / 5 / 6 / 6a / 6b / 17 / 17a / 17b).
Either way, the *intra-commit* ordering below is what keeps every
intermediate state buildable — see step 1 for the
`10 / 11 / 11a / 12` lockstep on the constant declaration, and
step 2 for the `15 / 16 / 7 / 8 / 9` lockstep on the registration.
The §6.D second-spectral-kind series used the
helper-extraction-first ordering for the same reason.

Recommended intra-slice ordering, finest-to-coarsest. The unit of
ordering is "one buildable commit". Build-system list updates and
the TUs they describe must land in the **same** commit — staging
site 8's `register_plugin(one_tap_delay_plugin_spec())` call
before sites 15 / 16 add the `one_tap_delay.cpp` TU to
[package.yaml](../package.yaml) and
[CMakeLists.txt](../CMakeLists.txt) would leave an undefined
reference at link time on both build paths.

1. Sites 10 + 11 / 11a / 12 **in one commit, in that order**:
   - 10 first declares `constexpr int kMaxPluginState = 4096`
     inside `namespace metasonic` in `rt_graph_plugins.h`.
   - 11 then adds
     `std::array<std::byte, metasonic::kMaxPluginState> storage{}`
     to `StaticPluginState` in `rt_graph.cpp` — referencing site
     10's constant by its fully-qualified name. Without site 10
     landing first, site 11 fails to compile.
   - 11a adds `#include <cstddef>` alongside the existing
     `<array>` include.
   - 12 adds the
     `static_assert(sizeof(StaticPluginState) <= sizeof(SpectralFreezeState), ...)`
     immediately after the struct definition; verifies the
     §4.1 free-ride before any plugin actually uses the storage.
2. Sites 15 / 16 + 7 + 8 / 9 **in one commit, in that order**:
   - 15 / 16 first add `tinysynth/plugins/one_tap_delay.cpp` to
     both build lists. The file does not exist yet; adding the
     path to `package.yaml` and `CMakeLists.txt` ahead of the TU
     is harmless on its own because the next step creates it
     within the same commit.
   - 7 creates `tinysynth/plugins/one_tap_delay.cpp` with the
     spec + `one_tap_delay_plugin_spec()` accessor (mirrors
     `identity.cpp`).
   - 8 / 9 then plumb `rt_graph_plugins.cpp` (register call,
     bound-check rewrite). The `register_plugin` call at this
     point links cleanly because steps 15 / 16 / 7 already
     introduced the symbol it references.

   Splitting any subset of these into a separate commit leaves a
   broken intermediate state — either the register call has no
   symbol (8 before 7), or the build lists do not see the TU
   (8 before 15 / 16). Keep them together.
3. Site 17c (C++ doctest cases for §5 test #13) — pins the
   `register_plugin` bounds check directly on the C++ side. Lands
   before the Haskell side picks up the catalog row so the
   registration discipline is enforced before any Haskell consumer
   can rely on it.
4. Sites 13 / 14 (zero-init in `init_node_state`, non-null state
   pointer in `process_static_plugin`) — activates the inline
   storage path. No `init` call site lands in v2. Identity tests
   still pass byte-equivalent because Identity keeps the nullptr
   branch.
5. Sites 1 / 2 / 3 (catalog row + safe accessors) — Haskell now
   knows about the second plugin.
6. Sites 4 / 5 / 6 / 6a / 6b (accessor migration in three
   consumers + user-facing wording refresh in Survey.hs and
   Compile/Latency.hs's module header) — the declared-latency /
   cost-lab story stays coherent across the slice, and the
   `--fusion-survey` output stops claiming "kindLatency-bearing"
   the moment per-instance plugin rows can appear in it.
7. Sites 17 / 17a / 17b (Haskell tests + test-component wiring) —
   counter-confirmed validation pins every step above. 17b must
   land before 17a or the new `AppFusionCostLab` test module will
   not see `MetaSonic.App.FusionCostLab`.

## 8. What this does NOT unblock

- **External plugin APIs.** LV2 / VST3 / CLAP / AU each still need
  their own adapter kind; v2 hosting protocol exists to be
  *adapted to* those APIs, not to *be* them. Same parking as
  v1.
- **Dynamic loading / discovery.** Build-time registry only.
- **Plugin GUIs / `tinysynth-ui`.** Independent series.
- **Multichannel plugins.** Single output per kind in v2; multichannel
  needs the same multi-output decision §6.C deferred.
- **Plugin parameters and parameter modulation.** v2 keeps the
  fixed `staticPlugin ref in0 in1` surface and the
  `controls = [plugin_id]` shape. A parameter-bearing plugin needs
  the [§6.E Q-4](2026-05-11-h-phase-6e-plugin-hosting-design.md)
  decision.
- **MIDI-in plugins.** §6.B MIDI dispatch is a separate surface.
- **Plugin-owned shared resources (bus/buffer reads/writes).**
  Both catalog rows declare `[Pure]`. A future plugin that
  legitimately needs to read or write a bus or buffer must first
  add the node-specific resource-metadata path the §6.E v1 design
  flagged in §3 — broadening `inferEff` for `KStaticPlugin` via
  the catalog's `spiEffects` field requires that path to exist
  before non-`Pure` rows are honest. The catalog's `spiEffects`
  field stays `[Pure]` for both rows in this slice. **Important:
  `Eff` is bus/buffer ordering, not "stateful DSP"** — see §1's
  non-claim note.
- **Plugin state migration across hot-swap.**
  `node_kind_supports_state_migration KStaticPlugin = false`
  stays; the new per-instance `storage` blob does **not** opt into
  Phase 5.2 migration. Adding migration requires per-plugin
  `supports_state_migration` + `migrate_state` design, same
  Q-deferral as v1.
- **Latency compensation.** `spiLatencySamples = 1` is descriptive;
  the
  [latency-compensation reopen gate](2026-05-11-e-phase-6d-latency-followup-decision.md)
  is unchanged. A second latency-bearing entity (after
  `KSpectralFreeze` / `KSpectralLpf`) does not by itself satisfy
  the reopen gate — the gate asks for a real corpus pattern with
  mixed latent/non-latent paths producing uncompensated skew, and
  this slice introduces no new corpus row.
- **Per-plugin scheduling refinement** (relaxing `CapHardBarrier`
  for stateless or latency-bearing-only plugins). Out of scope.
  Listed in [§6.E.3 Initial Scope](2026-05-11-n-phase-6e3-plugin-metadata-decision.md)
  as a follow-up.
- **`PluginSpec::init` / `::reset` callbacks of any kind.** v2
  never calls either callback. The v1 hosting contract's
  framing of these as producer-thread callbacks
  ([§6.E §2.2 / §2.4](2026-05-11-h-phase-6e-plugin-hosting-design.md))
  is left intact precisely because v2 introduces no call site that
  would force a contract update. The init-seam follow-up §9 Q-4
  documents the two candidate seams and the forcing function
  (a stateful plugin whose correct initial state is not all-zeros).
  Any plugin landed in v2 must be correct on a zero-initialized
  `storage[]` blob.

## 9. Open questions / Q-deferrals

Q-1. **Plugin name spelling.** `"one-tap-delay"` (kebab) matches
the proposed `spiLabel` and reads naturally next to `"identity"`.
The Identity row uses single-word casing so there is no
established multi-word convention yet; future rows pick from
{kebab, snake, single-word} based on the dominant pattern at that
time. Pin kebab in v2 and revisit if a registry-scanning tool
develops a preference.

Q-2. **Initial output sample.** The DSP body emits `out[0] = 0`
on the very first block (because `prev_sum` is zero-initialized).
An alternative is to defer the first output by one sample
(`out[0]` unwritten / silenced) and have downstream consumers
treat the delay opaquely. The contract picks `out[0] = 0` because
(a) the host always writes a full block worth of output and a
non-trivial "skip the first sample" contract would invent a new
output-shape vocabulary, and (b) zero is the well-defined value
of "the sum that would have occurred at sample `-1`" given
zero-initial state. The test in §5 #7 pins this explicitly.

Q-3. **`kMaxPluginState` size, again.** The v1 §2.1 design picked
4096 bytes "sized for the worst case among the reference plugins."
Both current plugins use ≤ 4 bytes. 4096 is wildly oversized today
but matches the v1 contract constant. Reopen only when a real
plugin (probably an FFT plugin, which would need ≈4 KiB of FFT
scratch alone) exceeds it; the right long-term answer is per-plugin
`state_size_bytes` plus a host-side allocation pool sized once at
registration ([§6.E Q-1](2026-05-11-h-phase-6e-plugin-hosting-design.md)).

Q-4. **`init` / `reset` seam — deferred to a follow-up contract.**
v2 calls neither callback from anywhere (see §4 opening). The
follow-up contract decides between two seams:

- **Producer-thread `init` via reshaped `init_node_state` signature.**
  Add `RTGraph &g` to `init_node_state`
  ([rt_graph.cpp:1713](../tinysynth/rt_graph.cpp)); the
  `KStaticPlugin` arm then calls
  `spec->init(storage.data(), g.sample_rate, g.max_frames)`.
  Honors the v1 hosting contract verbatim. Cost: every other
  `init_node_state` arm gets `RTGraph` access whether it wants it
  or not, and the change ripples through every caller (`add_node`
  at [rt_graph.cpp:1490](../tinysynth/rt_graph.cpp) etc.).
- **RT-safe-by-contract `init` from `process_static_plugin`.**
  Redefine `PluginSpec::init` in the v1 hosting header as a
  realtime callback with the same constraints as `process`
  (non-blocking, allocation-free, no syscalls). Cost: silently
  broadens every future plugin's `init`-side guarantees and
  invalidates the v1 hosting doc's explicit "producer thread"
  framing unless that note is also updated in the same slice.

The forcing function is a second stateful plugin whose correct
initial state is not all-zeros — most likely a sample-rate-
dependent filter (a one-pole LPF whose coefficient depends on
`g.sample_rate`) or a delay line with a non-zero ring start. Until
that user lands, both seams stay open and pinning either ahead of
the user repeats the "speculative design rejected by §6.E.3"
pattern.

Q-5. **Plugin-aware accessor location.** §7 site 4 places
`nodeDeclaredLatency` in `MetaSonic.Bridge.Compile.Latency`. An
alternative is to put it in `MetaSonic.Types` next to `kindLatency`.
Latency.hs wins on encapsulation (consumer-side), Types.hs wins on
discoverability (sits next to the thing it complements). Pick
Latency.hs in v2 to avoid a `Types.hs ↔ Source.hs` import cycle
(`Source.hs` defines the catalog and itself imports `Types.hs`).
Revisit only if a *non-latency* caller needs the same per-instance
metadata routing.

Q-6. **Counter pair separation.** v2 reuses the existing
`plugin_call_count` / `invalid_plugin_call_count` counters across
*all* plugins. Tests #9–#11 in §5 use total counts, not per-plugin
counts. If a future test needs to assert "this graph hit N Identity
calls and M one-tap-delay calls separately", the counter pair would
need to become per-plugin-id (an array indexed by `plugin_id`).
Defer until a real test asks. The minimum surface change today is
**no** new counter — total dispatch counts are sufficient for §5.

## 10. Review checklist before implementing

- [ ] §1 still the right second plugin, or has any consumer asked
      for something different in the meantime (a buffer plugin, a
      parameter-bearing plugin, a multichannel plugin)?
- [ ] §2 contract values still agree with the latest
      `staticPluginCatalog` (plugin id 1 still free, no other
      slice has claimed it).
- [ ] §3 accessor migration scope still complete. Three consumers
      were known at contract-write time:
      `declaredLatencyFootprint`,
      `nodeOutputLatencies`,
      and `FusionCostLab.extractFeatures`. Re-grep
      `kindLatency (rnKind ` across `src/`, `app/`, and `test/`
      before implementing — any new call site that landed since
      this note was written should join the migration in the same
      commit, or be explicitly noted as kind-level on purpose.
- [ ] §3 user-facing wording sweep still complete. Two strings
      were known at contract-write time:
      [Survey.hs:2209](../app/MetaSonic/App/Survey.hs)'s
      `"kindLatency-bearing nodes"` header and
      [Compile/Latency.hs:9-12](../src/MetaSonic/Bridge/Compile/Latency.hs)'s
      module header comment. Re-grep `kindLatency-bearing`,
      `kindLatency metadata`, and `kind-level latency` across
      `src/`, `app/`, and `test/` before implementing — any new
      user-visible string that asserts "kind-level latency" must
      land its refresh in the same commit as the §6 accessor
      migration or the survey output prints a wrong label next
      to correct numbers.
- [ ] §4 inline-blob alignment / size constants still correct
      against any C++ ABI changes (`std::max_align_t` is reliable
      on Linux x86-64 and aarch64; double-check if a new target
      lands).
- [ ] §4.1a plugin-state contract still respected. The single
      v2 plugin (`oneTapDelayPlugin`) ships a state struct that
      is (a) zero-valid (all-zeros is the meaningful initial
      state) and (b) implicit-lifetime / trivially copyable
      (scalar `float`). Any plugin that does not meet both
      conditions must wait for the init-seam follow-up §9 Q-4,
      because v2 does not call `spec->init` or placement-new on
      the storage.
- [ ] §4 still calls `spec->init` from nowhere. Re-grep
      `spec->init` and `\.init(` across `tinysynth/` before
      implementing — if any new call site has appeared since
      this note was written, it indicates the init-seam
      follow-up §9 Q-4 has already started landing and this
      slice should rebase on top of it instead of shipping
      around it.
- [ ] §4.1 free-ride invariant still holds. Check
      `sizeof(SpectralFreezeState)` before adding the
      `static_assert`; if spectral state has been moved
      out-of-line in the meantime, the `static_assert` will
      fail and the §4.1 contract requires the plugin storage to
      follow suit before this slice can land.
- [ ] §5 test list still complete after re-reading
      [StaticPlugin.hs](../test/MetaSonic/Spec/Feature/StaticPlugin.hs)
      and [Capability.hs](../test/MetaSonic/Spec/Feature/Capability.hs)
      — the `CoreShared.hs` / `Capability.hs` files already touch
      `identityPlugin` for representative-`UGen` selection; a
      second row may need a mirror update there. Check
      [test/MetaSonic/Spec/CoreShared.hs](../test/MetaSonic/Spec/CoreShared.hs)
      and the `KStaticPlugin -> StaticPlugin identityPlugin ...`
      row in
      [test/MetaSonic/Spec/Feature/Capability.hs](../test/MetaSonic/Spec/Feature/Capability.hs).
- [ ] §6 "no new corpus row" still the right call (revisit if a
      plugin-pattern row materializes elsewhere in the meantime).
- [ ] §7 sites table still reflects all the rows that need
      editing for the second catalog row + host-owned-state seam,
      with the explicit "no new kind" framing (no `kindSpec` /
      `kindLatency` / `kindCapabilities` / `portInfo` changes for
      `KStaticPlugin`).
