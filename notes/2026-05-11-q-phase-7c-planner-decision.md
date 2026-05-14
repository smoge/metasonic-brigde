# Phase 7.C Survey-Only Planner Decision

Date: 2026-05-11

Status: decision artifact for Phase 7.C. No runtime, C ABI, or
compiler-execution behavior changes in this slice; the planner is
diagnostic only and never produces a runtime program.

## Decision

Add a Haskell-only planner that walks the existing `RuntimeGraph`,
identifies **fusion candidates** at the granularity of contiguous
node segments within a single region, and emits a **verdict** for
each candidate: accepted as structurally legal, or rejected with a
structured reason. Output is diagnostic, surfaced through
`--fusion-survey`. Nothing executes.

This slice introduces the verdict-bearing data types but stays one
step short of a runtime program table; no FFI, no `RuntimeGraph`
change, no new `RegionKernel`.

## Legality Inputs

The planner reads five existing facts and combines them. It does
**not** introduce a new compiler-side classifier.

| Source                                                    | Shape                  |
| --------------------------------------------------------- | ---------------------- |
| `kindCapabilities :: NodeKind -> [KindCapability]`        | per-kind, §7.B         |
| `kindLatency     :: NodeKind -> Maybe Int`                | per-kind, §6.D         |
| `inferEff        :: UGen -> [Eff]`                        | per-UGen               |
| `rrFootprint     :: RuntimeRegion -> ResourceFootprint`   | per-region             |
| `rrKernel        :: RuntimeRegion -> RegionKernel`        | per-region (§4.B fact) |

`inferEff` is the source of truth for **which specific** bus or
buffer a UGen touches; `kindCapabilities` declares only that a kind
**may** touch a resource. The current planner slice uses kind-level
resource capability only; any future decision that depends on
resource identity (e.g. "this segment reads bus N and writes bus N")
must consult `inferEff` or an equivalent lowered per-node effect
surface.

## Why Not Use The `chain-caps` Union

The `chain-caps` column in `--fusion-survey` (commit `48f6476`) is a
**diagnostic breadcrumb**, not a legality model. It is a union of
flags carried by the chain's nodes, and that union is too coarse to
drive legality decisions:

- `CapResourceAccess` in the union does not distinguish a safe
  sink-terminal write (`KOut` at the tail, the chain's last node)
  from a hazard (a `KBusOut` in the middle of a chain, which bypasses
  the apparent terminal). The planner must reject the second and
  accept the first.
- `CapStatefulOp` in the union does not distinguish a fusible
  stateful node already handled by a §4.B kernel (e.g. `KLPF` in
  `Saw → LPF → Gain → Out`) from one that is not yet supported
  (e.g. `KSpectralFreeze` mid-chain).

7.C makes both calls at **node-level granularity** — it inspects
each node's position in the segment and its specific kind. Segment-
level reasons exist (e.g. "segment has no sink terminal", "segment
crosses a region boundary"), but the segment-level set is closed by
structural facts, not by flag unions.

### Concrete constraint

`shapeCapabilities` in `MetaSonic.App.Survey` is a survey helper and
**must not** be used by the planner. If the planner ever needs the
union for diagnostics, it computes its own from the segment's actual
node list — never from `SinkShape`.

## Candidate Identification

A **candidate** is a contiguous, dense-order sub-sequence of nodes
within a single `RuntimeRegion` such that the sequence ends in a
node with `CapSinkTerminal`. Candidates are formed deterministically
by scanning region members in dense order; identification is purely
structural and does not consult capability flags except for the
terminal check.

This is the same shape the §4.B kernel scan and the §7.A cost lab
already key off — keeping the candidate shape aligned with existing
tooling avoids inventing a third notion of "what a fusion unit is".

Candidate minimum length: 2 nodes (one stateful or stateless op plus
the sink). Single-sink-only candidates are dropped.

Candidates may be **nested** in the sense that a 4-node candidate
`A → B → C → sink` contains the 3-node candidate `B → C → sink`.
The planner reports both in the raw verdict stream, then exposes a
per-graph selected/maximal accepted-candidate view for survey and
snapshot tooling so future executor work does not treat suffixes as
separate generated targets.

## Per-Node Legality Rules

A candidate's positions are three classes:

- **Source** (position 0): the producer at the head of the chain.
- **True interior** (positions 1…n-2): the nodes strictly between
  source and sink.
- **Terminal sink** (position n-1): always `CapSinkTerminal`.

Each non-sink node is inspected in candidate order. The first
violated rule produces a node-level rejection reason and stops
evaluation. The position-aware split matches the §4.B kernel set
(`RSinGainOut` has `KSinOsc` at source; `RBusInLpfGainOut` has
`KBusIn` at source) — both are legal and the planner mirrors that.

The rules are checked in this priority order, per node:

1. **No hard barrier anywhere.** A node with `CapHardBarrier` at
   any position rejects the candidate. (Today this is only
   `KStaticPlugin`.) Position-independent: a plugin source is just
   as opaque as a plugin mid-chain.
2. **No latency-bearing anywhere.** A node with `CapLatencyBearing`
   at any non-sink position rejects. (The terminal sink does not
   declare latency today.) Position-independent: inlining across a
   latency boundary needs explicit handling whether the boundary is
   the producer or a mid-chain node.
3. **Resource access only at source or terminal sink.** A node with
   `CapResourceAccess` at a true-interior position (1…n-2) rejects.
   The source may carry `CapResourceAccess` (e.g., `KBusIn` reading
   a return bus), and the terminal sink always does. This is the
   rule that distinguishes a safe `KOut` at the tail from a
   hazardous `KBusOut` in the middle of a chain.
4. **Stateful kinds at true-interior positions must be on a known
   list.** A node with `CapStatefulOp` at position ≥1 (and not the
   sink) is rejected unless its kind is on the planner's narrow
   allow-list. The list is `[KLPF, KHPF, KBPF, KNotch]` at this
   slice — biquads only. The **source position is exempt**: a
   `KSinOsc`, `KSawOsc`, `KNoiseGen`, etc., as the chain's producer
   is fine (this is what §4.B's `RSinGainOut`, `RSawGainOut`, etc.
   already do). Adding kinds to the allow-list is a per-shape
   decision made against `--fusion-cost-lab` evidence, not just
   legality.
5. **No fanout escape.** Any non-sink node (including the source)
   with `rnConsumerCount /= 1` rejects. Duplicating a fanout
   producer is a profitability question, not a legality question,
   and the planner defers it.
6. **Adjacent members must be dataflow-adjacent.** For every
   neighboring pair in the candidate, the later node's principal
   signal input must be `RFrom` the previous member's port 0. Dense
   contiguity in a region is not enough: independent nodes can sit
   next to each other in topological order without forming a chain.

These rules are **per-node** by design: the planner cites the
specific `NodeIndex` and `NodeKind` that caused the rejection.

## Segment-Level Legality Rules

Four rules apply to the segment as a whole rather than to any
individual node.

1. **Terminal sink required.** Every candidate must end in a node
   with `CapSinkTerminal`. (Candidates are formed this way, so this
   rule is structural; it shows up as a rejection reason only if a
   future candidate-formation rule allows non-sink candidates.)
2. **Same-region only.** Candidates do not cross `RegionIndex`
   boundaries. (Region formation already enforces rate compatibility
   and effect-induced edges; the planner inherits both.)
3. **No fanout escape.** Every non-terminal node in the candidate
   must have `rnConsumerCount == 1`. A node that fans out cannot be
   absorbed without duplicating its work, and that decision belongs
   to the profitability model, not the legality model.
4. **Adjacent dataflow required.** Every consecutive pair must form
   the principal dataflow chain. A non-chain contiguous slice is a
   diagnostic candidate but not an executable fusion candidate.

## Rejection Reason Shape

Rejection reasons carry enough context to be useful both as a
diagnostic and as a future cost-model input.

```haskell
data RejectionReason
  = ReasonHardBarrier        !NodeIndex !NodeKind
  | ReasonLatencyMidChain    !NodeIndex !NodeKind !Int
  | ReasonResourceMidChain   !NodeIndex !NodeKind
  | ReasonStatefulInterior   !NodeIndex !NodeKind
  | ReasonFanoutEscape       !NodeIndex !Int          -- consumer count
  | ReasonNonAdjacentDataflow !NodeIndex !NodeIndex !NodeKind
  | ReasonTooShort           !Int                     -- length
  -- structural; included for future-proofing, not triggerable today:
  | ReasonNoTerminalSink
  | ReasonCrossesRegion      !NodeIndex
```

The names favor "what specifically failed" over a single
`UnsupportedShape` catch-all. Future expansion (e.g., feedback
detection) adds a new constructor rather than overloading an
existing one.

## Acceptance Verdict Shape

```haskell
data Verdict
  = Accepted  !FusionCandidate
  | Rejected  !FusionCandidate !RejectionReason

data FusionCandidate = FusionCandidate
  { fcRegion       :: !RegionIndex
  , fcMembers      :: ![NodeIndex]
  , fcMemberKinds  :: ![NodeKind]
  , fcMatchedShape :: !(Maybe RegionKernel)
    -- ^ The §4.B kernel that already claims this segment, if any.
    -- Used to surface "this is already covered by a hand-written
    -- kernel" so the planner does not double-count generated
    -- fusion candidates against shapes the existing kernel set
    -- already handles.
  , fcLengthNodes  :: !Int
  }
```

`fcMatchedShape` is the bridge between Phase 4's hand-written kernel
set and the Phase 7.C planner: a candidate that is `Accepted` and
has `fcMatchedShape = Just _` is an "already-claimed" candidate and
should not motivate a new generated kernel until the cost lab shows
the generated path beats the hand-written one.

## Profitability — Out Of 7.C

The planner reports **structural** facts only in this slice: node
count, region count, member kinds, matched-kernel shape. It does
**not** estimate ns/sample, compute speedup, or pick winners.

Profitability lives in Phase 7.A's cost lab. A future slice
(probably Phase 7.A continuation, not 7.C) joins the cost-lab rows
to planner verdicts by `(fcMatchedShape, fcMemberKinds)` and
produces the "fuse / do not fuse / needs benchmark" decision.

Keeping legality and profitability separate keeps the legality table
auditable and lets the cost model change independently.

## Surface

`--fusion-survey` gains one section:

```
─── Phase 7.C planner verdicts ───
  candidates=N  accepted=A  rejected=R  selected-accepted=S

  Top rejection reasons:
    ReasonResourceMidChain  count=…  example=node 7 KBusOut
    ReasonStatefulInterior  count=…  example=node 3 KEnv
    ReasonFanoutEscape      count=…  example=node 5 consumers=3

  Raw accepted candidates per matched shape:
    RSinGainOut       claimed=…  generated-eligible=…
    RSawLpfGainOut    claimed=…  generated-eligible=…
    no-§4.B-match     candidate-length=3  count=…

  Selected accepted candidates per matched shape:
    RSinGainOut       count=…
    no-§4.B-match     count=…
```

`--snapshot-check` pins raw total/accepted/rejected counts, selected
accepted/generated-eligible counts, and per-reason rejection counts.
Drift on any of them signals the candidate set or rule table changed.

## Initial Scope For The First Implementation Slice

1. New module `MetaSonic.Bridge.Planner` (or `MetaSonic.Fusion.Planner`
   — name to settle at code time). Pure functions; no `IO`.
2. `FusionCandidate`, `Verdict`, `RejectionReason` data types as
   sketched above.
3. `planRegion :: RuntimeRegion -> RuntimeGraph -> [Verdict]` for
   the per-region pass.
4. `planRuntimeGraph :: RuntimeGraph -> [Verdict]` for the whole-
   graph aggregator.
5. Per-rule unit tests in `test/Spec.hs`: each rule has a small
   `SynthGraph` that should trigger exactly that rejection.

Tooling and snapshot wiring follow in later slices of the series, in
this order:

- Survey output (`printPlannerVerdicts`).
- `--snapshot-check` pins.
- Roadmap sync.

## Out Of Scope For Phase 7.C

- A `FusionProgram` opcode/instruction encoding. The data type sketched
  here is a verdict, not a program. Op encoding belongs to Phase 7.D.
- Any C ABI surface, runtime program table, executor, or counter.
- Profitability decisions, ns/sample estimates, or "should fuse"
  output.
- A planner decision that overrides §4.B kernel selection.
- Cross-region candidates, cross-template candidates, or
  feedback-path detection.
- Fanout-with-duplication candidates.
- Per-instance refinement of plugin kinds (still parked behind
  §6.E.3).

## Open Questions Deferred Out Of 7.C

- **Stateful-interior allow-list.** The initial set
  `[KLPF, KHPF, KBPF, KNotch]` is conservative. Adding `KDelay` or
  `KSmooth` requires a `--fusion-cost-lab` row demonstrating
  benefit, not just legality. The allow-list lives in
  `MetaSonic.Bridge.Planner` and is intentionally a separate table
  from `kindCapabilities`.
- **Cost-lab join over selected candidates.** The planner now exposes
  selected/maximal accepted candidates, but the cost-lab still needs
  to join those rows to measured features before Phase 7.D can make
  execution decisions.
- **Module placement.** `MetaSonic.Bridge.Planner` keeps the planner
  in the bridge tree alongside `IR.hs`, `Compile.hs`, `FFI.hs`. The
  alternative `MetaSonic.Fusion.Planner` signals a separate sub-tree
  that may eventually hold the Phase 7.D opcode encoding. Either is
  fine; settle at code time.
