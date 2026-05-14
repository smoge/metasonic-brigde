# Session Prep I - Scripted Pattern Runner

Date: 2026-05-13

Status: draft decision artifact. This slice promotes the inline
producer/queue/owner composition that already lives in Prep H tests
into a single named library boundary. It is still not a thread-safe
fan-in layer, background scheduler, OSC/MIDI/UI adapter, audio-thread
queue, or preserving hot-swap implementation.

## Decision

Add `MetaSonic.Session.Runner`. Export one caller-driven step function:

    stepPatternSession
      :: Pattern
      -> PatternProducerState
      -> SessionCommandQueue
      -> SessionOwner
      -> IO PatternRunnerStepResult

with an explicit step-result record that names every observable piece
the call composes:

    data PatternRunnerStepResult = PatternRunnerStepResult
      { prsState   :: !PatternProducerState
      , prsQueue   :: !SessionCommandQueue
      , prsEnqueue :: !PatternEnqueueResult
      , prsDrain   :: !SessionDrainResult
      }

The v1 contract should:

1. Call `enqueuePatternBlock` exactly once.
2. Call `drainSessionCommandQueue` exactly once, against the queue
   returned by step 1.
3. Surface the producer state and queue from step 2 as the caller's
   carry-forward state.
4. Surface the enqueue report and the drain report unchanged.
5. Add no thread, clock, retry loop, sleep, or background drain.
6. Add no new producer/owner vocabulary; the runner is pure composition.

The goal is to turn Prep F/G/H into one observable offline/demo loop
without inventing a session runtime. A caller wanting to keep stepping
inspects `isBacklogged (prsState r)`, `sdrStopped (prsDrain r)`, and
`perNextStart (prsEnqueue r)` and decides whether to call again.

## Why This Slice Now

The producer/queue/owner triple already composes cleanly inline. Prep H
tests already exercise:

    let outcome = enqueuePatternBlock pat producer queue
    result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner ->
      drainSessionCommandQueue owner (peoQueue outcome)

That composition is the entire scripted runner. Promoting it to a named
function:

- moves the composition out of test fixtures so non-test callers
  (offline demos, future scheduled callers, ad hoc REPL sessions) can
  drive a session without rebuilding the wiring;
- gives the loop a single observable step record so divergence,
  backlog, and cursor progress are inspectable without destructuring
  three intermediate values;
- pins the order (enqueue then drain) at one site rather than relying
  on every caller to remember it.

Anything bigger - thread-safe fan-in, cross-producer arbitration, a
background drain loop, an OSC/MIDI bridge, preserving hot-swap - is a
separate decision with its own failure surface. Prep I deliberately
stays single-threaded and caller-driven so the next slice can choose
between OSC/MIDI ingress, preserving hot-swap, and arbitration on
evidence rather than vibes.

## Recap: Existing Contracts Used Here

`MetaSonic.Session.PatternProducer` provides:

    enqueuePatternBlock
      :: Pattern
      -> PatternProducerState
      -> SessionCommandQueue
      -> PatternEnqueueOutcome

    isBacklogged :: PatternProducerState -> Bool

`MetaSonic.Session.Queue` provides:

    drainSessionCommandQueue
      :: SessionOwner
      -> SessionCommandQueue
      -> IO (SessionCommandQueue, SessionDrainResult)

`MetaSonic.Session.Owner` provides scoped owner construction through
`withSessionOwner`. The runner does not own the owner bracket; callers
do. This keeps the runner pure-ish (it does IO only because the owner
step itself does), composable with any owner-lifetime story, and free
of any opinion about graph install or teardown order.

## Step Semantics

`stepPatternSession` is one synchronous pass:

1. `enqueuePatternBlock pat state queue` runs first. Either it retries
   the existing backlog (no fresh range), or it generates one range and
   enqueues it. This is unchanged from Prep H.
2. `drainSessionCommandQueue owner (peoQueue outcome)` runs second
   against whatever queue the enqueue returned. The drain may stop
   early on owner divergence; that is reported through `sdrStopped`,
   not by throwing.
3. `prsState`, `prsQueue` are the post-drain producer state and
   queue. `prsEnqueue` and `prsDrain` are the two sub-reports.

Across consecutive calls:

- If `isBacklogged (prsState r)` is true, the next call retries
  backlog. The cursor does not advance.
- If `sdrStopped (prsDrain r)` is `Just _`, the owner has diverged.
  Further calls still type-check, but every drained item will be
  `SessionOwnerBlocked` until the owner is rebuilt. The runner does
  not paper over this; callers decide whether to tear down and rebuild.
  Caller obligation: treat `sdrStopped /= Nothing` as a stop or rebuild
  signal. The runner's fixed enqueue-then-drain order means that a
  caller who keeps calling after divergence will still advance the
  producer cursor (or rebuild backlog) and accumulate queued items
  that the next drain will only mark as blocked - never a crash, but
  not progress either.
- `perNextStart (prsEnqueue r)` is the producer cursor after the call.
  Pair it with the Pattern's known end position to detect exhaustion.

A "drain to quiescence" or "step until backlog clears" loop is a
caller responsibility, not a runner responsibility. Adding one in v1
would commit to a policy about when the loop terminates, and the
honest answer depends on whether the caller is rendering offline,
driving an interactive demo, or fronting a future scheduler.

## Out Of Scope

- Wall-clock pacing. The runner takes no `IO` clock.
- Thread creation. The runner makes no `forkIO` call.
- Multi-producer fan-in. Only one Pattern producer; no arbitration.
- Hot-swap policy. The runner forwards `PEHotSwap` events through the
  existing producer/queue/owner path. Preserving hot-swap is a
  separate slice.
- Audio-thread visibility. The runner is Haskell-only.

## Testing

The four tests pinned for Prep I:

1. One-block step commits one voice through the owner. Mirrors Prep H's
   end-to-end test but goes through `stepPatternSession`.
2. Backlog retry across repeated runner steps. A capacity-1 queue
   plus three voice-on events forces step 1 to enqueue one and hold
   two as backlog. Step 2 retries the backlog, drains one, and still
   leaves one held over. Step 3 retries the remaining backlog and
   clears it. Expected `perBacklogged` sequence across the three
   steps is 2, 1, 0; `isBacklogged` flips false only after step 3,
   and all three voices appear in `ssVoices` (the test overrides
   per-template polyphony so the owner accepts more than one voice
   per template).
3. Drain stop on owner divergence. A `PEHotSwap` with a malformed
   graph drives the owner to `SodHotSwapInstallFailed`. The runner
   reports `sdrStopped = Just _` and later steps still type-check,
   producing `SessionOwnerBlocked` items.
4. No fresh range during backlog recovery. After a small-capacity
   first step leaves backlog, the second step's cursor must equal the
   first step's cursor, and the only enqueued items are the held-over
   backlog entries.
