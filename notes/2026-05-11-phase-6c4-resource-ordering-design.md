# Phase 6.C.4 — Buffer Resource Ordering (Design)

Date: 2026-05-11
Status: design / contract preflight; no code lands here. Bounds
the resource-ordering layer that 6.C.4 ships *before* any writer
UGen lands. The first writer (a minimal `RecordBufMono`) is the
following step, designed in its own note once this layer is
agreed.

## Why this comes before the writer

Today every cross-template ordering decision flows through
`BusFootprint` ([Compile/Types.hs:670](../src/MetaSonic/Bridge/Compile/Types.hs#L670)):
the precedence rule is

  *A precedes B  ⇔  bfWrites(A) ∩ bfReads(B) ≠ ∅*

with delayed reads excluded. The same shape is reused at three
scopes (template / region / node) — see `Note [Bus footprints,
template- vs region-level]`. That works exactly as long as the
only shared resource that induces ordering is a bus.

6.C.3a/b shipped `BufRead` (via `KPlayBufMono`) with `inferEff`
already pinning `BufRead (bufferId buf)` on the node's
`irEffects`, but `busFootprint` deliberately ignores the entry —
a `BufRead` alone induces no template precedence (read-only +
identical reads across instances are commutative; one of
6.C.1's settled choices). The moment a `BufWrite` exists, that
exemption breaks: `BufWrite` on buffer N from template X must
precede `BufRead` on buffer N from template Y, exactly the same
shape as the bus rule but keyed on buffer ID instead of bus
index. Adding the writer first would either (a) ignore the
ordering and rely on instance-vector luck — silently wrong — or
(b) tangle buffer-keyed precedence into `BusFootprint` at the
point of writer introduction. Both are worse than landing the
ordering surface first.

6.C.4 is the resource-ordering preflight. After it lands, the
writer is mechanical to add: extend `busFootprint` (now a
projection of the broader extractor) to record `BufWrite`, and
the existing precedence-derivation step picks it up unchanged.

## What 6.C.4 is and is not

In scope:

- **`ResourceFootprint` shape.** Wrap or replace `BusFootprint`
  with a type that carries the bus fields *and* a parallel set
  of buffer fields (reads, writes, optional delayed reads).
- **Bus-only-graph behavior is preserved.** Every existing test
  that exercises `BusFootprint` continues to pass with identical
  precedence output.
- **`BufRead` alone stays non-ordering.** Matches 6.C.1
  decision 6; aggregate fold collects the buffer ID set, but
  the precedence rule's left-hand side is `BufWrite`-only.
- **`BufWrite → BufRead` on the same buffer adds an edge.**
  Same structure as the bus rule, keyed on buffer ID.
- **Same-buffer `BufWrite / BufWrite` is a compile error in
  v1.** See section 4 for the rationale; the alternative
  (deterministic input-order serialization) is recorded as
  6.C.5+ work.

Out of scope (do not touch in 6.C.4):

- No `RecordBufMono` or any other writer UGen yet. The kind
  needs the ordering surface in place first, but the writer's
  own contract (audio-thread write path, write-head semantics,
  retire-during-write behavior) belongs in its own design note.
- No file I/O, async load, multichannel, OSC `/buffer/*`.
- No 6.D spectral. Spectral wants a clean resource story, not a
  resource story being formed mid-flight.

## The type-level move

Three viable shapes, in order of disruption to existing code:

### Option A — wrap (preferred)

```haskell
data BufferFootprint = BufferFootprint
  { bfBufWrites        :: !(S.Set Int)
  , bfBufReads         :: !(S.Set Int)
  , bfBufDelayedReads  :: !(S.Set Int)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

data ResourceFootprint = ResourceFootprint
  { rfBuses   :: !BusFootprint
  , rfBuffers :: !BufferFootprint
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)
```

Callers that only need bus footprints stay on `BusFootprint`;
the new template-level / region-level interface is
`ResourceFootprint`, which is what `Template.tplFootprint` and
`RuntimeRegion.rrFootprint` carry going forward.

Pros:

- Existing `bfWrites` / `bfReads` / `bfDelayedReads` field
  names keep working through `rfBuses`.
- `busFootprint :: GraphIR -> BusFootprint` keeps a useful
  meaning (projection from `ResourceFootprint`). Bus-only
  callers do not pay for buffer fields they never inspect.
- The wrap is fully backwards-compatible at the test level
  — existing precedence tests on bus-only graphs assert on the
  same shape via `rfBuses`.

Cons:

- One more layer of nesting. `tplFootprint . rfBuses . bfWrites`
  is two dots instead of one. Mitigated by re-exporting field
  accessors at the `ResourceFootprint` level
  (`rfWrites = bfWrites . rfBuses` etc.) — pure ergonomics, no
  semantic shift.

### Option B — replace, with bus aliases (rejected)

Drop `BusFootprint`; rename the type to `ResourceFootprint` and
make every accessor poly-resource (`rfBusWrites`,
`rfBufWrites`, etc.). Cleaner final shape, but every existing
call site changes name, every test message string drifts, and
the wrap option already gives the same final ergonomics with a
smaller blast radius.

### Option C — keep `BusFootprint`, add a sibling extractor (rejected)

Leave `BusFootprint` alone, add `bufferFootprint :: GraphIR ->
BufferFootprint`, run two precedence derivations and union the
edges. Easy to land. Wrong long-term: every consumer that
reasons about "the resources a unit of execution touches" now
has to pair the two extractors manually. Sets up tangling later.

Decision: **A**.

## The precedence rule

With `ResourceFootprint`, the inter-template precedence
derivation in
[Templates.hs](../src/MetaSonic/Bridge/Templates.hs) generalizes:

  *A precedes B  ⇔  writes(A) ∩ liveReads(B) ≠ ∅*

where

```
writes(A)     = rfBuses A `bfWrites`  ∪  rfBuffers A `bfBufWrites`
liveReads(B)  = rfBuses B `bfReads`   ∪  rfBuffers B `bfBufReads`
```

Bus and buffer indices live in disjoint namespaces — the union
is over (kind, id) pairs, not raw ints, so a bus 5 / buffer 5
collision is impossible.

`bfDelayedReads` and `bfBufDelayedReads` are recorded for
diagnostics but do not contribute to precedence (matches the
existing bus rule and matches §6.C.3a's intent for
`BufReadDelayed` if it ever lands).

The cycle-detection step is unchanged — DFS over the
reader-keyed edge set is exactly the same; only the edge
derivation step learned to look at one more resource axis.

## Same-buffer `BufWrite / BufWrite` — reject in v1

Two templates that both write the same buffer in the same block
have no defensible default ordering:

- "Input order" (the order the producer registered them in
  `compileTemplateGraph`) is observable but implicit. A user
  reordering templates for any reason — e.g. moving a section
  in their score — silently changes audio output. That is the
  exact class of footgun §1's compile-time-ordering principle
  exists to prevent.
- "Tagged order" (a producer-provided priority) is a feature
  in search of a use case; the user can already make the
  ordering explicit by chaining the writes through a bus.

Reject same-buffer `BufWrite / BufWrite` at
`compileTemplateGraph` with a dedicated diagnostic
(`MultipleWritersOnBuffer bufId [tplNames]`) modelled on the
existing cycle / duplicate-name diagnostics. The producer's
escape hatch is to express the ordering through a bus or by
splitting into separate buffers — both make intent explicit.

If a real use case appears later (e.g. mixdown into a single
record buffer from multiple voices), 6.C.5 can lift the
restriction with a pinned ordering primitive. Designing that
primitive on speculation is what makes resource layers
calcify.

Same-buffer `BufRead / BufRead` stays allowed and unordered
(commutative, identical reads — 6.C.1's principle for buffers
mirrors the bus case where `BusIn / BusIn` is unordered).

## Implementation sketch

Five focused PRs / commits; each one runs `stack test` clean
before the next lands:

1. **Add `BufferFootprint` and `ResourceFootprint` types** in
   `Compile.Types`, with `emptyResourceFootprint` /
   `emptyBufferFootprint` helpers. No call site touches them
   yet; the new types are unused.
2. **Pivot `Template.tplFootprint` and `RuntimeRegion.rrFootprint`
   to `ResourceFootprint`.** Update the extractor in
   `busFootprint`'s file to return `ResourceFootprint` (or add
   `resourceFootprint`; pin the name choice in the contract
   note). Existing tests that pattern-match on the field shape
   need one mechanical update; bus-only behavior is
   bit-identical.
3. **Teach the template-level precedence step to union bus +
   buffer edges.** New tests:
     - `BufWrite → BufRead` on the same buffer adds the edge.
     - `BufWrite` against itself in a different buffer does
       not.
     - Bus-only corpus precedence is byte-identical to today.
4. **Reject same-buffer `BufWrite / BufWrite`.** New
   diagnostic constructor + tests.
5. **Update [ROADMAP.md](../ROADMAP.md)** with the 6.C.4 entry
   flipped to `[x]`. The 6.C.5 placeholder reserves the
   "lift the restriction" decision.

The order matters: the type lands first so the precedence step
can be rewritten without a parallel-running fallback, and the
new diagnostic lands last so the corpus survey can be re-run
without false positives in steps 2 and 3.

## What this unblocks

Once 6.C.4 is in:

- A `RecordBufMono` UGen kind (designed in its own note) only
  has to set `[BufWrite bufId]` in `inferEff`; the ordering
  machinery picks it up automatically. The runtime work is
  scoped to the kernel itself (write head, audio-thread store
  ordering against `BufferSlotState`, retire-while-writing
  behavior) rather than tangled with cross-template scheduling.
- 6.E plugin hosting inherits a uniform "resource footprint"
  contract for plugin-owned buffers without further surgery.
- 6.D spectral can consume `ResourceFootprint` as-is if
  spectral-domain buffers ever become first-class resources.

## What it deliberately does not unblock

Audio-thread writes are still gated by 6.C.4's *follow-up*
design note for `RecordBufMono`. 6.C.4 alone does not change
runtime semantics — it changes only how the compiler reasons
about ordering once a writer exists. No `process_graph` code
moves in this phase.
