# OSC operator event rendering design (2026-05-22)

Status: design note for a narrow Phase 8b polish slice.

## Trigger

The Phase 8b saw/noise OSC pass validated the richer repertoire as
playable, but it made the accepted-write diagnostics visibly
operator-hostile:

```text
osc accept: CmdControlWrite voice=v0 tag=ControlTag {ctNodeTag = MigrationKey {unMigrationKey = "gain"}, ctSlot = 0} value=0.18000000715255737
```

This is not a new correctness failure. It is renderer friction:
operator-facing text leaks constructor names, migration-key record
syntax, and binary floating-point noise.

Opening this slice is a small relaxation of the strict "one transcript
is not pressure" rubric. The justification is that three substantive
operator passes have now produced no competing lane, and the OSC pass
is exactly the pass that made repeated accept lines common enough to
judge. Waiting for a second complaint risks training operators to
ignore noisy lines rather than improving the shell.

## Contract

Accepted OSC control writes should render as an operator event, not as
a `SessionCommand` dump.

Preferred shape:

```text
osc accept: /v0/gain/0 name="level" value=0.18
```

Fallback shape when no manifest binding matches the command's
`ControlTag`:

```text
osc accept: /v0/lpf/0 value=1200
```

The fallback is deliberate. The accepted command always carries a
voice key plus `ControlTag`; the friendly display name is metadata
from the current `ManifestOSCControlBinding` list. Rendering must not
fail, drop the line, or invent a name if that binding is missing.

Float formatting decision: accepted values render as compact decimal
display text with trailing zeroes removed from the mantissa. The goal
is to remove common IEEE representation noise
(`0.18000000715255737` -> `0.18`, `0.699999988079071` -> `0.7`) while
keeping the line compact. Exponent notation is permitted as an
implementation detail for values outside the normal Phase 8b control
ranges, but the exact switch thresholds are not part of the contract.
This is an operator display contract, not a serialization contract.

## Plumbing

The binding lookup belongs at listener-hook construction time.

`renderControlBindingMetadata` is the precedent for keeping
manifest-control display metadata as the source of truth. The accept
formatter should receive the current `ManifestOSCControlBinding` list
and resolve `(ControlTag -> display name)` from it. The live-session
ingress should pass that list into the formatter for each opened
ingress generation, because preserving reloads close and reopen OSC
against the current manifest target.

The intended behavior is:

- target-specific hooks use `motControls (mitOSC target)` for
  metadata-aware accept lines;
- unmatched tags fall back to the address-only shape;
- existing issue rendering keeps its current taxonomy;
- rejection formatting is not widened in this slice.

## Out of scope

- Current-value introspection.
- GUI/control binding work.
- Readline or command history.
- ALSA stderr suppression.
- Same-demo reload special-casing.
- Changing manifest schema or generated JSON.
