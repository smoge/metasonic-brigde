# Manifest OSC range rejection (2026-05-21)

Date: 2026-05-21

Status: **design**. No code yet. Next commit lands the contract below.

This note scopes the next Phase 8 / live-session slice surfaced by the
first run of the
[live-session operator pass playbook](2026-05-21-b-live-session-operator-pass-playbook.md).
The playbook's first operator pass sent
`/v0/lpf/0 value=0.75` against the `preserve-cutoff-dark` fixture,
whose manifest declares the cutoff as `Hz` in `[200, 6000]`. The OSC
ingress accepted the packet, the LPF set its cutoff to `0.75 Hz`, and
the drone became inaudible — the operator initially read this as an
audio glitch. The runtime is RT-safe; what's missing is a contract
enforcement at the manifest-aware ingress site.

## Problem

The `--manifest-live-session` OSC ingress promises the operator a
"manifest-aware" surface: addresses are validated against the current
plan's control namespace, removed tags reject, new tags appear (see
[2026-05-20-d-stale-command-rejection-rendering.md](2026-05-20-d-stale-command-rejection-rendering.md)
for the rejection-rendering family this slice extends). The promise
the operator inferred — and that the addressable-surface line
`/v0/lpf/0 (name="cutoff")` reinforces — is that the manifest's
declared metadata is *binding*. In practice today, the projection
carries `rangeMin`/`rangeMax` for diagnostics only:

- `ManifestOSCControlBinding` has `mocbRangeMin :: !Double` and
  `mocbRangeMax :: !Double` populated from
  `mcsRangeMin`/`mcsRangeMax`
  ([ManifestReloadOSCBinding.hs:46-54](../app/MetaSonic/App/ManifestReloadOSCBinding.hs#L46-L54),
  [85-98](../app/MetaSonic/App/ManifestReloadOSCBinding.hs#L85-L98)).
- `validateOSCControlTag` returns the binding so callers *could* use
  it
  ([ManifestReloadOSCBinding.hs:114-123](../app/MetaSonic/App/ManifestReloadOSCBinding.hs#L114-L123)),
  but the only current caller `submitManifestOSCMessage` binds the
  binding to `_binding` and forwards the original OSC message
  unchanged through `enqueueOSCControlWrite`
  ([ManifestReloadOSCIngress.hs:71-81](../app/MetaSonic/App/ManifestReloadOSCIngress.hs#L71-L81)).
- The MIDI side of the same projection *does* use the range
  meaningfully: `scaleCCValue` linearly maps CC `0..127` through
  `[rangeMin, rangeMax]`
  ([ManifestReloadMIDIIngress.hs:133-136](../app/MetaSonic/App/ManifestReloadMIDIIngress.hs#L133-L136)),
  so the MIDI surface already treats the manifest range as load-bearing
  for the producer's emitted `Value`.

The asymmetry is the load-bearing finding: MIDI honors the range
(by construction, because CC is unitless and must be scaled), OSC
ignores it (because OSC carries raw units and could just pass them
through). Operators reading the addressable-surface line have no
way to distinguish "tag exists" from "value will land within
declared range" — and the LPF's silent-when-near-DC behavior makes
the difference audible.

## Contract

Manifest-aware OSC ingress validates the *value* against the
binding's `[rangeMin, rangeMax]` after the existing tag validation
and before the producer enqueue. The check is a **reject**, not a
clamp:

```text
osc reject (out-of-range): tag=<node-tag>/<slot> value=<v> range=[<min>, <max>]
```

The label slots into the existing `(parse) / (manifest) /
(reload-window)` family
([renderOSCIssueLine](../app/MetaSonic/App/ManifestLiveCommon.hs#L529-L539)).
Tag rendering reuses `renderManifestOSCAddressTail`
([ManifestReloadOSCBinding.hs:131-133](../app/MetaSonic/App/ManifestReloadOSCBinding.hs#L131-L133))
so the rejection line names the same address shape the operator
sent.

**Reject, not clamp.** OSC values are raw units. Silently clamping
`0.75` to `200` would land an audible cutoff that the operator did
not ask for and would not see. Rejecting keeps audio stable (the
producer is never called, so no `CmdControlWrite` enters the
fan-in), and the printed line tells the operator exactly which
range to send within. Clamping is also harder to undo later if a
future Phase 8 lane wants to surface "would-have-been-clamped"
warnings; the rejection lane is the strict superset.

**Inclusive bounds.** The accept predicate is
`value >= rangeMin && value <= rangeMax`. Clients may legitimately
want to send exactly the declared min or max — `200.0` and `6000.0`
for the preserve-cutoff fixture both accept. This slice does not
add a load-time check that `rangeMin <= rangeMax` or that the
manifest's `default` lies within `[rangeMin, rangeMax]`; if the
manifest is degenerate (e.g. `rangeMin > rangeMax`), this predicate
rejects every OSC write to that control, which is at least a
loud failure mode rather than silent acceptance.

**No producer side effects on reject.** The fan-in host sees nothing.
The session command never decodes a second time inside
`enqueueOSCControlWrite`; `submitManifestOSCMessage` returns
`ManifestOSCIngressResult (Left (MoiiValueOutOfRange ...))` and
exits. Wrapper grep contracts on `osc accept:` and the existing
rejection lines remain unchanged because the new line is its own
family member.

**Scope is the manifest-aware ingress only.** The legacy raw OSC
listener
([OSCProducer.hs](../src/MetaSonic/Session/OSCProducer.hs))
that has no projection target stays permissive — there is no
manifest, so there is no declared range to check against. This
slice does *not* touch `enqueueOSCControlWrite` or the producer
ABI; the range check happens one layer above.

## Investigation findings

Both questions are code-readable. Recorded so the implementation
plan does not rediscover them.

**1. Where does the `Value :: Double` for the range comparison
come from?** The decoded `SymbolicControlWrite` already carries
it: `scwValue :: !Value` with `type Value = Double`
([Dispatch/Internal.hs:175-179](../src/MetaSonic/OSC/Dispatch/Internal.hs#L175-L179),
[Pattern.hs:76](../src/MetaSonic/Pattern.hs#L76)). The binding's
`mocbRangeMin`/`mocbRangeMax` are also `Double`. The comparison
is `Double` vs `Double` with no conversion; the only NaN concern
(see below) is whether to reject NaN as out-of-range or treat it
as a separate parser-level rejection. Recommend reject as
out-of-range with the literal `NaN` rendering — it is structurally
outside any finite `[min, max]` and rendering it through the same
line keeps the operator surface uniform.

**2. Is `validateOSCControlTag` still tag-only after this slice?**
Yes. The function's signature stays
`ControlTag -> ManifestOSCIngressTarget -> Either
ManifestOSCAddressIssue ManifestOSCControlBinding`. Range
validation happens at the next layer
(`submitManifestOSCMessage`), surfaced as a third `Manifest
OSCIngressIssue` constructor rather than widening the address-
issue newtype. The address-issue type stays exclusively about
address namespace (currently a `newtype` around
`MoaiUnknownControl`); the value-domain rejection is a sibling at
the ingress layer, not a member of the address-issue type. This
keeps the read-path discoverable: when an operator finds an `osc
reject (out-of-range)` line, the next investigation step is the
ingress-issue type, not the address-issue type.

## Implementation plan

Two-file change. One pure renderer extension, one ingress-call
extension, plus tests. Suggested split across two commits for
review symmetry with the `2026-05-20-d` shape, but a single commit
is fine if the diff stays small.

**Commit 1 — types and renderer (pure, deterministic):**

1. Add the new constructor to `ManifestOSCIngressIssue`
   ([ManifestReloadOSCIngress.hs:42-45](../app/MetaSonic/App/ManifestReloadOSCIngress.hs#L42-L45)):

   ```haskell
   data ManifestOSCIngressIssue
     = MoiiDecodeFailed     !DispatchIssue
     | MoiiAddressIssue     !ManifestOSCAddressIssue
     | MoiiValueOutOfRange  !ControlTag !Double !Double !Double
       -- ^ tag, value, rangeMin, rangeMax
     deriving (Eq, Show)
   ```

2. Extend `renderOSCIssueLine`
   ([ManifestLiveCommon.hs:529-539](../app/MetaSonic/App/ManifestLiveCommon.hs#L529-L539))
   with the new arm. The address tail render reuses
   `renderManifestOSCAddressTail`. Sketch:

   ```haskell
   MoliManifestIssue (MoiiValueOutOfRange tag value lo hi) ->
     "osc reject (out-of-range): tag=" <> renderManifestOSCAddressTail tag
       <> " value=" <> show value
       <> " range=[" <> show lo <> ", " <> show hi <> "]"
   ```

   (Listener wrapping: `MoliManifestIssue` already carries
   `ManifestOSCIngressIssue` end-to-end through
   `processManifestOSCPacket` → `molhOnIssue`, so the renderer arm
   matches the wrapped constructor pattern of the existing
   `MoliManifestIssue` cases.)

3. Test module
   `MetaSonic.Spec.AppManifestLiveCommonOSCRender` already exists
   from the `2026-05-20-d` slice. Add three rows:
   - `MoiiValueOutOfRange (ControlTag (MigrationKey "lpf") 0) 0.75 200 6000`
     → exact string.
   - NaN row: render `MoiiValueOutOfRange ... (0/0) ...` and pin
     whatever `show (0/0 :: Double) = "NaN"` produces so the
     string is locked.
   - Zero-width range row: `rangeMin == rangeMax == 0.0`, rejecting
     `0.1`. Pins the renderer against a degenerate-but-legal
     manifest range without depending on ingress accept/reject
     behavior (boundary-acceptance rows live in commit 2).

**Commit 2 — ingress behavior (effectful, against fixtures):**

1. In `submitManifestOSCMessage`
   ([ManifestReloadOSCIngress.hs:71-81](../app/MetaSonic/App/ManifestReloadOSCIngress.hs#L71-L81)),
   replace the `Right _binding` arm with a value-range check.
   Sketch:

   ```haskell
   Right (SymbolicControlWrite _voiceKey tag value) ->
     case validateOSCControlTag tag target of
       Left addrIssue ->
         pure (ManifestOSCIngressResult (Left (MoiiAddressIssue addrIssue)))
       Right binding
         | value < mocbRangeMin binding || value > mocbRangeMax binding
             || isNaN value -> do
             let lo = mocbRangeMin binding
                 hi = mocbRangeMax binding
             pure (ManifestOSCIngressResult
                    (Left (MoiiValueOutOfRange tag value lo hi)))
         | otherwise -> do
             producerResult <- enqueueOSCControlWrite opts msg host
             pure (ManifestOSCIngressResult (Right producerResult))
   ```

   The producer is **not** called on the out-of-range arm, so no
   `CmdControlWrite` enters the fan-in queue.

2. Behavior tests in
   [AppManifestReloadOSCIngress.hs](../test/MetaSonic/Spec/AppManifestReloadOSCIngress.hs):
   - value at `rangeMin` accepted (producer called, ingress
     result wraps `Right OSCProducerEnqueueAttempted`);
   - value at `rangeMax` accepted (same);
   - value `rangeMin - epsilon` rejected
     (`Left (MoiiValueOutOfRange ...)`, producer not called);
   - value `rangeMax + epsilon` rejected (same);
   - NaN rejected (same);
   - unknown tag still rejects as `MoiiAddressIssue` (unchanged
     behavior; pin as regression guard).

3. Higher-level confirmation in
   [AppManifestOSCIngressOps.hs](../test/MetaSonic/Spec/AppManifestOSCIngressOps.hs):
   one row threading an out-of-range packet through the full
   manifest ops surface and asserting the listener-hook `molhOn
   Issue` fires with `MoliManifestIssue (MoiiValueOutOfRange ...)`.
   This confirms the end-to-end wiring; pure tests in commit 1 pin
   the rendered string.

The "producer not called" assertion in the behavior tests is the
counter-confirmed evidence that out-of-range rejects do not enter
the fan-in queue. Implement it by passing an in-process fan-in
host whose enqueue records calls (or asserting on the queue's
post-condition).

## Tests / exit criteria

Deterministic, no live IO:

1. **Renderer rows** (commit 1, in
   `AppManifestLiveCommonOSCRender`): 3 new rows covering the
   `MoiiValueOutOfRange` arm — typical case, NaN, and zero-width
   range (`rangeMin == rangeMax` — both `0.0`, rejecting `0.1`).
2. **Ingress behavior rows** (commit 2, in
   `AppManifestReloadOSCIngress`): 6 rows as listed above.
3. **Ingress-ops fan-out** (commit 2, in
   `AppManifestOSCIngressOps`): 1 row.

No tier-2 wrapper assertion this slice. Triggering an out-of-range
packet from a wrapper is straightforward (the existing OSC sender
can send `0.75` against the preserve-cutoff fixture), but the
operator-facing line is already pinned at the renderer layer by the
deterministic tests. Wrapper coverage is optional and can land in a
follow-up if pressure surfaces.

## Out of scope

- **Clamp option / "would-have-been-clamped" warnings.** This slice
  is reject-only. A future clamping mode would be additive (e.g.
  a per-control manifest field `outOfRange: reject | clamp`) and
  needs its own design when an operator asks.
- **Unit metadata in the addressable-surface line.** The first
  operator pass also noted that `/v0/lpf/0 (name="cutoff")` does
  not tell the operator the value is in Hz with `[200, 6000]`.
  Surfacing the range there would close the same friction from a
  different direction. Tracked separately under the
  [playbook's Findings section](2026-05-21-b-live-session-operator-pass-playbook.md);
  this slice is rejection-only.
- **Legacy raw OSC listener.** The non-manifest OSC path stays
  permissive (no projection = no declared range).
- **MIDI side.** Already honors `rangeMin`/`rangeMax` by
  construction (`scaleCCValue` linearly maps CC `0..127`).
- **UI ingress.** UI control writes already go through a different
  ingress with its own value vocabulary; range enforcement there is
  a separate question.
- **Range validation at manifest load time.** This slice adds no
  numeric validation at parse / projection time. The manifest
  parser today reads `rangeMin` / `rangeMax` as plain aeson fields
  ([Manifest.hs:212-213](../src/MetaSonic/Authoring/Manifest.hs#L212-L213))
  and `validateManifestTemplates` only checks template-shape /
  catalog consistency
  ([ManifestReload.hs:237-240](../src/MetaSonic/Session/ManifestReload.hs#L237-L240));
  there is no check today that `rangeMin <= rangeMax` or that
  `default ∈ [rangeMin, rangeMax]`. Whether to add those (or
  cross-reload checks like surviving-tag range monotonicity) is a
  separate authoring / manifest-validation slice, out of scope
  here.

## Commit shape

Plan: two commits.

1. **Types and renderer.** `MoiiValueOutOfRange` on
   `ManifestOSCIngressIssue`; new arm in `renderOSCIssueLine`; 3
   renderer rows. Touches:
   - `app/MetaSonic/App/ManifestReloadOSCIngress.hs`
   - `app/MetaSonic/App/ManifestLiveCommon.hs`
   - `test/MetaSonic/Spec/AppManifestLiveCommonOSCRender.hs`
   - `package.yaml` (only if hpack regenerates `.cabal`; likely not
     needed for this slice).

2. **Ingress behavior.** Range check in `submitManifestOSCMessage`;
   6 behavior rows + 1 fan-out row. Touches:
   - `app/MetaSonic/App/ManifestReloadOSCIngress.hs`
   - `test/MetaSonic/Spec/AppManifestReloadOSCIngress.hs`
   - `test/MetaSonic/Spec/AppManifestOSCIngressOps.hs`

A single combined commit is acceptable if the diff stays under
~150 LoC. The two-commit shape is preferred for review symmetry
with `2026-05-20-d`'s `144901f + 737b124` split: pure contract,
then behavior. Suite should grow by ~10 deterministic cases.
