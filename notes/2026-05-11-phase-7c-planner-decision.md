# Phase 7.C Survey-Only Planner Decision

Date: 2026-05-11

Status: decision artifact for Phase 7.C. No runtime, C ABI, or
compiler-execution behavior changes in this slice; the planner is
diagnostic only and never produces a runtime program.

## Decision

Add a Haskell-only planner that walks the existing `RuntimeGraph`,
identifies **fusion candidates** at the granularity of contiguous
node segments within a single region, and emits a **verdict** for
each candidate: accepted with a structured benefit estimate, or
rejected with a structured reason. Output is diagnostic, surfaced
through `--fusion-survey`. Nothing executes.

This slice introduces the `FusionProgram` representation as the
verdict-bearing data type but stays one step short of a runtime
program table; no FFI, no `RuntimeGraph` change, no new
`RegionKernel`.

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
**may** touch a resource. The planner consults `inferEff` whenever a
decision depends on resource identity (e.g. "this segment reads bus
N and writes bus N").

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
The planner reports both and lets the consumer (cost-lab consumer in
a later slice) decide whether to coalesce.

## Per-Node Legality Rules

Each node in a candidate is inspected against the rules below in
order. The first violated rule produces a node-level rejection
reason and stops evaluation of that candidate.

1. **No hard barrier mid-chain.** A node with `CapHardBarrier`
   anywhere in the candidate rejects the candidate. (Today this is
   only `KStaticPlugin`.)
2. **No latency-bearing mid-chain.** A node with `CapLatencyBearing`
   anywhere except as the terminal sink rejects the candidate. (The
   terminal sink does not declare latency.)
3. **Resource access only at the terminal sink.** A node with
   `CapResourceAccess` that is not the candidate's last node rejects
   the candidate. The last node is required to have both
   `CapSinkTerminal` and `CapResourceAccess`.
4. **Stateful interior nodes must be on a known list.** Today the
   list is `[KLPF, KHPF, KBPF, KNotch]` and only when the candidate
   matches a §4.B-recognizable shape (matched against the existing
   `RegionKernel` set: `RSinGainOut`, `RSawLpfGainOut`, etc.). Other
   stateful interior nodes (`KEnv`, `KDelay`, `KSmooth`, oscillators
   mid-chain) reject the candidate. The list is deliberately narrow
   at this slice; expanding it is a per-shape decision made against
   `--fusion-cost-lab` evidence.

These rules are **per-node** by design: the planner cites the
specific `NodeIndex` and `NodeKind` that caused the rejection.

## Segment-Level Legality Rules

Three rules apply to the segment as a whole rather than to any
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
  accepted=N  rejected=M  matched-by-§4.B=K  matched-no-kernel=L

  Top rejection reasons:
    ReasonResourceMidChain  count=…  example=node 7 KBusOut
    ReasonStatefulInterior  count=…  example=node 3 KEnv
    ReasonFanoutEscape      count=…  example=node 5 consumers=3

  Accepted candidates per matched shape:
    RSinGainOut       claimed=…  generated-eligible=…
    RSawLpfGainOut    claimed=…  generated-eligible=…
    no-§4.B-match     candidate-length=3  count=…
```

`--snapshot-check` pins three numbers: total accepted count, total
rejected count, and per-reason rejection counts. Drift on any of
them signals the candidate set or rule table changed.

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
- **Nested-candidate coalescing.** Reporting both 3-node and 4-node
  candidates for the same chain is fine for diagnostics but
  inefficient for the cost-lab join. The right fix is in the
  cost-lab side, not the planner.
- **Module placement.** `MetaSonic.Bridge.Planner` keeps the planner
  in the bridge tree alongside `IR.hs`, `Compile.hs`, `FFI.hs`. The
  alternative `MetaSonic.Fusion.Planner` signals a separate sub-tree
  that may eventually hold the Phase 7.D opcode encoding. Either is
  fine; settle at code time.
