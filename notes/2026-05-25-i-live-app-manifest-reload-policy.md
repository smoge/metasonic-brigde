# Live-App Manifest Reload Policy Owner

Date: 2026-05-25

Status: design note, no code. Scopes the *boundary* of a concrete
policy owner for `runManifestLiveSession`. It decides who owns
what, not what fields the record carries, not how the record
mutates, and not how it lowers into the FFI. The first code slice
after this note can be a pure app-profile / projector test (no
real OSC socket, no PortMIDI device, no audio host changes).

## Anchors

- `runManifestLiveSession` at
  [app/MetaSonic/App/ManifestLiveSession.hs L922](../app/MetaSonic/App/ManifestLiveSession.hs#L922)
  — the current live-session entrypoint. Takes
  `ManifestReloadHostStrategy`, manifest path, initial demo,
  `ListenerConfig`, and an optional MIDI device index. Resolves
  doc / catalog / plan, opens a host stack, runs the supervised
  loop, and threads operator commands into the line-editor wrap.
- `ManifestReloadIngressTargetPolicy` at
  [app/MetaSonic/App/ManifestReloadIngressTarget.hs L48](../app/MetaSonic/App/ManifestReloadIngressTarget.hs#L48)
  — the existing pure ingress-projection policy record. UI voice
  selection, UI retained-value seed, MIDI default voice. Already
  consumed by `manifestReloadIngressTargetFromPlan`. *Not* a
  live-app policy: it answers \"what does the next ingress target
  look like on this plan?\", not \"what should the session do
  with it?\".
- `RealReloadHostStackInputs` at
  [app/MetaSonic/App/ManifestReloadHostStack.hs L456](../app/MetaSonic/App/ManifestReloadHostStack.hs#L456)
  — producer-supplied inputs to the substrate `realOpen` /
  `realClose` path. Already carries `rrhsiServiceOptions ::
  SessionFanInServiceOptions` (which in turn carries
  `sfsoArbitrationGatewayOptions`), `rrhsiOwnerOptions`,
  `rrhsiAudioOptions`, the ingress-target policy, and the event
  sinks. Every supervised route (stopped-audio / preserving /
  try-preserving) threads this same record. So the arbitration
  profile already has a slot in the host stack — it just isn't
  filled by anyone at the app layer today.
- ROADMAP gates: GUI / live-app reload/resource policy at
  [ROADMAP.md L3756](../ROADMAP.md#L3756) and arbitration
  mutation / voice-lifecycle ownership clearing at
  [ROADMAP.md L3824](../ROADMAP.md#L3824). Both stay gated by
  this note's outcome — see Non-Goals.

## What's missing today

`runManifestLiveSession` makes five separate policy decisions in
its body without naming them:

1. **Strategy selection** — `ManifestReloadHostStrategy` is
   passed in as an argument and not revisited. There is no
   per-demo or per-reload override; an operator who wants
   `RequirePreserving` for one demo and `StoppedAudioOnly` for
   another has to relaunch.
2. **Ingress lifecycle** — `manifestLiveIngressOps` decides which
   producers are opened (OSC always; MIDI iff
   `mMidiDevice` is `Just`), how they re-bind across reloads
   (preserving keeps the listener thread; stopped-audio closes
   and reopens), and how their issue paths fold into the
   supervisor's collapse events. The choice is implicit in which
   argument was passed, not declared.
3. **Device / socket lifetime** — `ListenerConfig` is one OSC
   port for the process lifetime. The PortMIDI device, if any,
   is one index; if it disappears we collapse. UI has no socket
   today and the producer is wired in-process. There is no
   uniform statement of \"these resources live for the session,
   these for the stack, these for the reload window\".
4. **Arbitration profile** — `sfsoArbitrationGatewayOptions`
   ends up `Nothing` everywhere at the app layer (FIFO default)
   because nobody constructs the gateway options. The arbitrated
   producer helpers and the two `--session-*-arbitration-smoke`
   probes exist, but production live sessions never opt in.
   `arbitrationProfile = FifoOnly` is the *implicit*
   live-session policy; there is no place to write
   `ProducerPriority` or `TargetClaim` and have it survive a
   reload.
5. **Resource policy during reload** — queue sizing
   (`SessionFanInOptions`), service hooks (`SessionFanInServiceHooks`),
   audio options, owner options, retired-voice sink, audio-event
   sink, ingress-event sink. All five live in
   `RealReloadHostStackInputs` today and are picked by the
   supervisor wiring with no app-layer policy record above them.

None of those five are bugs. They are reasonable defaults that
worked while the live session had one shape. The cost of leaving
them implicit is that any of the gated work above (GUI bindings,
per-demo strategy override, opt-in live arbitration, runtime
resource adjustment) has no record to extend — every future
caller would re-thread the same set of underspecified arguments.

## The boundary this note decides

There is **one policy owner** for the live-app reload surface.
Call it the *live-app reload policy* for the rest of this note;
its concrete type name is not decided here. It splits into two
values:

- A **pure policy record** constructed by
  `runManifestLiveSession`'s caller (`Main`'s argument-parsing
  path today, a host application's session-builder later).
  Pure means: no `IO`, no `MVar`, no socket / device /
  audio-host effects. It carries shapes and defaults — the
  strategy resolver (a pure function value), the ingress
  profile, the resource scope split, the initial arbitration
  profile, and the resource-policy bundle (the comparable
  sub-records: `SessionFanInOptions`,
  `SessionFanInAudioOptions`, `SessionOwnerOptions`, and the
  pure parts of `SessionFanInServiceOptions`). The caller can
  keep it in a config file, derive it from command-line flags,
  or build it from a GUI form — none of that is the record's
  concern.
- A **runtime projection context** allocated inside
  `runManifestLiveSession` (or supplied by a test fixture
  that mimics it). The context holds the IORefs, MVars, and
  sinks that the existing inputs already close over today:
  `reloadEventsRef`, `audioEventsRef`, `lastRetiredRef`,
  `extPrintRef` / `extPrintDyn`, the line-discipline output
  sink, and the supervisor-facing event callbacks built on top
  of them. It is *not* part of the pure policy because today's
  callbacks at
  [ManifestLiveSession.hs L1038–L1064](../app/MetaSonic/App/ManifestLiveSession.hs#L1038-L1064)
  capture refs created at
  [ManifestLiveSession.hs L949–L972](../app/MetaSonic/App/ManifestLiveSession.hs#L949-L972),
  and any boundary that pretends those callbacks are
  caller-supplied would either force the caller into `IO` or
  duplicate the runtime state.

- A **projector** of type `Policy -> Context -> LoweredInputs`
  (rough shape; concrete name and signature decided in the
  first code slice). The projector is pure in the sense that
  given the same `(policy, context)` it builds the same
  `RealReloadHostStackInputs`,
  `ManifestReloadIngressTargetPolicy`,
  `SessionFanInServiceOptions` (including
  `sfsoArbitrationGatewayOptions`), `SessionFanInServiceHooks`,
  and the per-reload event-sink callbacks. The context's
  callbacks are referentially the IO actions the projector
  embeds in the lowered records; the test fixture supplies a
  context whose callbacks write to test-owned `IORef`s so
  behavioral assertions can observe them.

- Consumed by **`runManifestLiveSession` only**. Neither the
  policy nor the context travels below into
  `MetaSonic.Session.*` (those keep their current narrow
  records) and neither travels into `MetaSonic.Bridge.*`. The
  arrows point: caller → policy; `runManifestLiveSession` →
  context; (policy, context) → projector → host stack inputs
  → session substrate.

The five axes from the previous section are exactly what the
policy + context together cover, and nothing else.

### Axis 1 — Strategy selection

The owner names the **strategy resolver**: a function from
`Demo` (or whatever the next-reload identity is in the new
shape) to `ManifestReloadHostStrategy`. The default resolver
returns the single CLI-supplied strategy, matching today's
behavior. A later GUI binding can supply a resolver that reads
from a UI-managed strategy table per demo without
`runManifestLiveSession` learning about the UI.

The owner does *not* decide how supervisor escalation overrides
the resolver. That stays in the supervision lane (see the
2026-05-25-f / -g / -h notes); the resolver is consulted at the
*start* of each reload attempt, and the supervisor's terminal /
repair pathway is unchanged.

### Axis 2 — Ingress lifecycle

The owner names the **ingress profile**: an explicit declaration
of which producer surfaces participate (UI / OSC / MIDI), with
the per-surface lifetime span (process / stack / reload-window)
attached to each. Today's behavior is the constant profile
`{OSC across process, MIDI-if-just across process}` plus
ingress-reopen on stopped-audio reload, ingress-keep on
preserving. The owner makes that profile a value; future
operator surfaces can swap it.

The owner does *not* decide the producer wire format, the
session command vocabulary, or the FanIn fan-in policy. Those
stay in `MetaSonic.Session.*` and are referenced, not duplicated.

### Axis 3 — Device / socket lifetime

The owner names the **resource scope** for each producer
surface in the ingress profile. The substrate already has three
distinguishable scopes, and today's behavior is not a single
scope across the board:

- **Per-session config values** are constants the caller hands
  in once and the substrate carries unchanged across reloads.
  Today these are `ListenerConfig` (one OSC port for the
  process) and the optional MIDI device index. They sit on
  `runManifestLiveSession`'s argument list.
- **Per-stack resource handles** are acquired and released by
  every `realOpen` / `realClose` pair. The host stack contract
  is explicit about this: `rrhsiBuildIngressOps` is a function
  that takes a *just-opened* `SessionFanInHost` and returns a
  fresh ingress ops bundle, because the old host is gone by the
  time the supervisor rebuilds. The fan-in service, ingress
  manager, and audio start/stop also live at this scope.
- **Per-reload-window scope** depends on strategy: the
  preserving lane keeps the ingress listener thread across the
  in-window reload; the stopped-audio lane closes and reopens
  it. That choice is currently implicit in
  `ManifestReloadHostStrategy` and is enforced by which factory
  the supervisor instantiates.

The owner's job is to make those three scopes *named* per
producer surface, with today's behavior as the default
projection: per-session config flows in from the CLI args,
per-stack handles flow through `rrhsiBuildIngressOps` and
friends, per-reload-window behavior follows the strategy from
Axis 1. A later live-app caller that wants, e.g., per-stack
PortMIDI rebinding so an unplugged device can be recovered by
reload, attaches that scope here without
`runManifestLiveSession` growing a special case.

The owner does *not* implement reacquisition policy on failure.
That stays in the supervisor; the policy owner only declares
*intent* about lifetime.

### Axis 4 — Arbitration profile

The owner names the **arbitration profile**: which producers
participate in arbitration, which gateway policy
(`FifoOnly`, `ProducerPriority`, `TargetClaim`) applies, and
which arbitration smoke evidence the profile points back to
(`--session-osc-arbitration-smoke` /
`--session-midi-arbitration-smoke`). The projector lowers the
profile into `sfsoArbitrationGatewayOptions` on the service
options it hands to the host stack.

Default profile is `FifoOnly`, matching today's implicit
behavior. The owner records the choice explicitly so a later
live-app caller can opt into a non-FIFO policy without changing
`runManifestLiveSession`.

Mutation of the policy *after* gateway construction
(claim release, owner clearing, claim replacement) is NOT
decided here — ROADMAP L3824 keeps it gated on a concrete
release / hot-swap / voice-key-reuse use case. The owner records
the **initial** profile only; if a later use case wants
runtime mutation, it adds an explicit mutation handle alongside
the initial profile rather than rewriting the boundary.

### Axis 5 — Resource policy during reload

The owner names the **resource policy bundle**:
`SessionFanInOptions` (queue capacity), service hook shape,
audio options, owner options, retired-voice sink, audio-event
sink, ingress-event sink. The projector spreads these across
`RealReloadHostStackInputs`. Today every entry is the existing
hard-coded default; the policy owner makes them defaults of a
named record rather than ad-hoc literals.

This unblocks per-demo or per-stack overrides (e.g., a demo
with a very fast pattern wants a larger fan-in queue) without
churning every supervisor call site.

## Non-goals

- **No mutation API on the policy record.** The record is
  constructed once per session by the caller. If a future
  use case needs mid-session mutation, it earns its own slice
  with a concrete release / reuse signal, per ROADMAP L3824.
  Until then the live session reconstructs the policy on
  next process launch.
- **No GUI binding.** The policy record is a Haskell value
  with no UI affinity. GUI work behind ROADMAP L3756 builds
  a GUI surface that *produces* the record; it does not
  reach into the record's projector or
  `runManifestLiveSession`.
- **No new FFI.** The boundary is entirely Haskell. The
  projector lowers into existing session-layer records that
  already cross to C++ via existing entrypoints.
- **No producer-policy override.** The arbitration profile
  picks among existing arbitration substrate options; it does
  not redefine `Session.Arbitration`, `ArbitrationGateway`, or
  any per-producer arbitrated helper.
- **No new live-session feature.** Today's behavior is exactly
  the default policy. The boundary exists to give future
  features (per-demo strategy, opt-in live arbitration, fan-in
  queue resizing, scoped device lifetime) a place to attach.

## Relationship to the gated ROADMAP items

The two gated bullets above this note both depend on this
boundary:

- **ROADMAP L3756** (GUI / live-app reload/resource policy) is
  blocked on \"what does the GUI configure\". The policy owner
  is that answer. Once the boundary is named, GUI work can
  proceed against a stable target without touching session
  internals.
- **ROADMAP L3824** (arbitration mutation / voice-lifecycle
  ownership clearing) is blocked on \"who would call the
  mutation, with what release signal\". The policy owner is
  where the mutation handle would live if and when a concrete
  caller asks for it. Until that caller exists, the owner
  records *initial* profile only and the gated bullet stays
  closed.

Neither item is unblocked by this note — both stay gated until
their own use cases land. The boundary just removes
\"we don't have a place to put it\" as a reason they cannot
move.

## First code slice after this note

A pure app-profile / projector test. Shape:

1. Define the live-app reload policy record and the runtime
   projection context (placeholder names; fields fall out of
   the five axes above), and the projector
   `Policy -> Context -> LoweredInputs`.
2. Construct a fixture policy that matches today's implicit
   defaults (CLI-supplied strategy, OSC + optional MIDI
   ingress, the scope split from Axis 3 above, `FifoOnly`
   arbitration, current resource bundle) and a fixture
   context whose callbacks each write to a test-owned
   `IORef` so the test thread can read them back.
3. Project it. The lowered value cannot be compared whole
   with `(==)` because both `RealReloadHostStackInputs` and
   `SessionFanInServiceHooks` carry function fields
   (`rrhsiBuildIngressOps`, `rrhsiOnEvent`, `rrhsiOnRetired`,
   `rrhsiOnAudioEvent`, `sfshOnDrain`, `sfshOnIssue`). The
   assertion bar splits in two:
   - **Structural equality** on the comparable sub-records
     and fields: `SessionFanInServiceOptions` (especially
     `sfsoArbitrationGatewayOptions`), `SessionFanInOptions`,
     `SessionFanInAudioOptions`, `SessionOwnerOptions`,
     `ManifestReloadIngressTargetPolicy`. These derive `Eq`
     and can be checked against a fixture-built reference.
   - **Behavioral assertions** on the callback fields:
     `rrhsiOnEvent`, `rrhsiOnAudioEvent`, `rrhsiOnRetired`,
     `sfshOnDrain`, and `sfshOnIssue` can be driven with a
     known input on the test thread and the corresponding
     fixture-owned `IORef` inspected afterwards.
     `rrhsiBuildIngressOps` is the awkward one: it takes a
     `SessionFanInHost`, whose constructor is intentionally
     private — see
     [FanIn.hs L22](../src/MetaSonic/Session/FanIn.hs#L22)
     for the export list and
     [FanIn.hs L110](../src/MetaSonic/Session/FanIn.hs#L110)
     for the "constructor stays private" note. The first
     projector test should *not* invoke it; assert only that
     the projector set the field at all (e.g., compare it
     against a sentinel by construction-time tag stored in
     the policy/context, or check that the projector's
     by-construction wiring closes over the expected pieces
     of the context). A later slice can call
     `rrhsiBuildIngressOps` against a real host opened via
     `withSessionFanInHost` / `openSessionFanInHost` over a
     small fixture `TemplateGraph` (real host, no audio
     start, brackets close cleanly) and recurse the
     structural-plus-behavioral split into the returned
     `ManifestReloadIngressOps`.
4. Construct a second fixture that flips exactly one axis
   (e.g., arbitration profile to `TargetClaim` for a fixed
   `(VoiceKey, ControlTag)`). Project it. Assert the only
   structural difference is `sfsoArbitrationGatewayOptions`
   and that the callback behaviors observed in step 3 are
   unchanged at the relevant probe points.

No socket. No device. No audio host. No reload supervisor.
The test stays inside the projector; it is the same shape
as the existing pure manifest-binding tests, with the same
`stack test` integration.

Two testing principles apply, inlined here so the note is
self-contained:

- **The test suite stays in-language.** No subprocess
  shell-outs from Haskell tests to validate Python or shell
  tools; wire-format coverage uses byte fixtures on both
  sides and connects at the format boundary. The projector
  test is pure Haskell against Haskell records.
- **Counter-confirmed validation, not just byte equality.**
  Each behavioral assertion includes a side-channel counter
  that fires only when the projector code path actually ran,
  so a future refactor that short-circuits to a hard-coded
  fixture cannot make the assertion vacuously pass.

After the projector test lands, the next slice is wiring
`runManifestLiveSession` to consume the policy record instead
of its current ad-hoc arguments, with `Main` constructing the
default policy from current CLI flags. That slice does not
add features; it converts the implicit policy to an explicit
one. Feature slices (per-demo strategy resolver, live
arbitration opt-in, resource overrides) come one at a time
after that, each gated on its own use case.

The two-slice plan above (projector test, then wiring) has now
landed; the planning paragraphs are kept for historical
reference. "Slices landed" below records the realized state, and
"Boundary coverage closed" records that the deferred behavioral
gap is now covered.

## Slices landed

- **Projector slice.** `MetaSonic.App.ManifestLivePolicy` defines
  the pure `LiveAppReloadPolicy`, the runtime
  `LiveAppReloadContext`, and the `projectLiveAppReloadPolicy`
  function. The companion spec
  `MetaSonic.Spec.AppManifestLivePolicy` pins the default
  projection against today's implicit values, isolates the
  `TargetClaim` arbitration flip to `sfsoArbitrationGatewayOptions`,
  proves the projector composes `staleByReloadDrainHook` from
  context refs, and round-trips strategy / listener config / MIDI
  device through `defaultLiveAppReloadPolicy`.
- **Wiring slice (012781b).** `runManifestLiveSessionWithPolicy ::
  FilePath -> Demo -> LiveAppReloadPolicy -> IO ()` is the
  policy-native entrypoint. The body builds a
  `LiveAppReloadContext` from the existing IORefs / sinks /
  ingress builders and calls `projectLiveAppReloadPolicy` instead
  of hand-rolling `RealReloadHostStackInputs`. Strategy
  resolution is one-shot against the initial demo, matching
  today's one-strategy-per-session behavior. The old
  `runManifestLiveSession` stays as a thin compatibility wrapper
  that constructs `defaultLiveAppReloadPolicy`. `Main` was
  switched to the policy-native entrypoint. `just stack-test`
  passes 1578 tests after the wiring slice.
- **Ingress-profile coverage slice (d112a53).** New test
  "projected `rrhsiBuildIngressOps` threads policy ingress
  profile through context builder" in
  `MetaSonic.Spec.AppManifestLivePolicy`. Opens a real
  `SessionFanInHost` via `withSessionFanInHost` over
  `TemplateGraph [] M.empty` (no socket, no PortMIDI, no audio,
  no supervisor), projects the policy, invokes
  `rrhsiBuildIngressOps` to get the bundled ingress ops, drives
  `mrioOpenIngress`, and asserts the `LiveIngressProfile`
  captured inside the stub builder's closure equals
  `larpIngressProfile policy`. The stub returns a sentinel
  `LiveProdIngressIssue` so the `Left` payload is also pinned.

## Boundary coverage closed

The deferred behavioral gap the earlier slices intentionally
left — invoking `rrhsiBuildIngressOps` against a real
`SessionFanInHost` to prove `LiveIngressProfile` reaches the
context builder — is now closed by the coverage slice above.
The boundary's behavioral surface (structural-equal sub-records,
counter-confirmed IORef callbacks, composed drain hook,
default-constructor round-trip, real-host ingress-profile
threading) is fully covered.

The backlog reduces to use-case-gated feature slices (GUI
binding, per-reload strategy changes, live arbitration opt-in
via the existing `LiveArbitrationProfile` field, resource
overrides, arbitration mutation), all of which stay gated on a
concrete caller per this note's non-goals.

## Open questions deferred to later notes

- Should the policy record be one flat record or composed
  from per-axis sub-records? Pragmatic answer for the first
  slice: one flat record with the five axes as fields, refactor
  later if a sub-record would be reused by an unrelated caller.
- How does the policy record interact with multi-session
  hosts (one `Main` launching several `runManifestLiveSession`
  instances)? Out of scope for the first slice; today the
  session is process-singleton.
- Where does the policy record live in the module layout? A
  new module under `MetaSonic.App.*` is the natural home;
  picking the exact name is the first slice's call.
