# Session Prep O - Live-Audio Preserving Hot-Swap Orchestration

Date: 2026-05-13

Status: implemented session-adapter live-audio preserving hot-swap
orchestration. This slice does not add OSC/MIDI/UI producers, add a
background drain loop, change queue fan-in, or add recovery after
divergence.

Prep K fixed the preserving hot-swap policy. Prep L pinned the stale
queued-command semantics. Prep M chose runtime migration for the first
supported implementation. Prep N implemented that migration path for
the stopped-audio scripted session adapter. Prep O extends the same
contract to the case where the audio callback owns `process_graph`.

## Decision

Live-audio preserving hot-swap uses the existing RCU swap protocol
without calling `rt_graph_process` from the session thread.

The live path is:

1. validate the same `PreservingHotSwapPlan` Prep N already uses;
2. build an offline next `RTGraph` with the target handle's
   `capacity` and `max_frames`;
3. seed active builder slots matching preserved `VoiceBinding` slot
   ids and template ids;
4. capture the target's current swap generation;
5. prepare a swap from the builder;
6. publish the swap;
7. wait for the audio callback to advance the swap generation;
8. collect the retired swap and inspect migration counters;
9. commit `CommitGraphInstalled` only after lifecycle and state-copy
   counts prove the preserved voices migrated.

If the target has no active audio stream, the existing Prep N scripted
path remains valid: it drains queued realtime commands and installs the
published swap with zero-frame `rt_graph_process` calls. If audio is
running, the session adapter must use the generation-wait path instead.

## Ownership Boundary

Before publish succeeds, the session thread owns the prepared swap. A
publish rejection must cancel the prepared swap and return a
non-terminal retryable runtime issue, matching
`SriHotSwapPublishRejected`.

After publish succeeds, ownership has transferred to the runtime. The
session thread no longer has a local pointer it may cancel. From that
point onward, the session state cannot safely continue claiming the old
graph if the orchestration loses track of install completion.

That ownership split drives the failure policy below.

## Failure Policy

Publish rejection is non-terminal. The runtime has not taken ownership
of the prepared swap, so the session owner can keep its current state
and callers may retry later.

Install timeout is terminal divergence for the current owner. A timeout
after successful publish does not prove the swap failed; the audio
thread may still install it after the session call returns. Until the
session layer has an explicit repair/recovery protocol, the owner must
stop accepting commands rather than risk stale `SessionState`.

Retired-swap missing after observed generation advance is terminal
divergence. The install appears to have happened, but the session layer
cannot inspect migration counters. Without those counters it cannot
prove preserved voices survived.

Migration-counter failure is terminal divergence. The runtime installed
a new active world but did not report enough lifecycle/state copies to
justify committing the preserving swap.

Unsupported preserving shapes remain non-terminal rejections before
publish. They should keep using `SriHotSwapWouldPreserveVoices`, as in
Prep N.

The implementation maps the new terminal live-audio failures through
the existing `SriHotSwapInstallFailed` wrapper with precise runtime
text. `ownerDivergence` already treats that wrapper as terminal, so
post-publish timeout, retired-missing, and incomplete migration block
the owner until a future repair protocol exists.

## Timeout Policy

The live path needs an explicit timeout because waiting for the audio
thread is now part of the session step. The runtime adapter exposes
`raoHotSwapInstallTimeoutMs` on `RTGraphAdapterOptions`; the owner
passes it through via `sooAdapterOptions`.

For tests and scripted tools, a small finite timeout is enough. For
interactive hosts, the caller may choose a larger timeout or a
supervised background flow. An infinite wait is acceptable only for
callers that can tolerate blocking the session step until audio
advances.

Timeout starts after publish succeeds. Time spent compiling/loading the
offline builder is not an install timeout; failures before publish
still leave the owner on the old graph.

## Serialization Contract

The v1 contract remains single hot-swap producer / single collector per
`RTGraph` handle. `waitForSwapGeneration` captures a prior generation
and waits for it to advance; with multiple concurrent hot-swap
producers, one producer could observe another producer's install.

The session host or future producer service must serialize hot-swap
steps for one target handle. This does not solve generic OSC/MIDI/UI
fan-in. Those producers still need a separate arbitration policy before
they can submit graph swaps concurrently.

Realtime voice/control commands published before the audio callback
installs the swap drain against the old world. Commands published after
the session observes generation advance and commits target the new
world. The session-side queue/host should hold the session step lock
across publish, wait, collect, verification, and commit, so no later
session command is admitted against ambiguous graph state.

## Reuse From Prep N

The live path should reuse the Prep N validation and builder work:

- preserved binding extraction from the commit-time resolve rebuild;
- same-template-id checks for preserved bindings;
- destination-driven stateful-node validation;
- supported/unsupported node-kind classification;
- preserved-slot seeding and prewarm metadata construction;
- migration-counter verification.

The only behavioral split is the install driver:

- stopped audio: zero-frame scripted process step;
- running audio: publish, wait for generation, collect retired swap.

## Test Coverage

The library tests model the live orchestration failure policy without
starting PortAudio. `Session Prep O: live preserving hot-swap
orchestration` uses a mock `SessionRuntimeAdapter` to cover:

- publish rejection returning non-terminal retryable failure;
- install timeout after publish mapping through the terminal
  `SriHotSwapInstallFailed` wrapper;
- generation advance with missing retired swap mapping through the
  terminal wrapper;
- incomplete migration counters mapping through the terminal wrapper.

Hardware-backed PortAudio tests should stay optional. The library tests
can keep modeling the live path with a mock adapter or a deterministic
fake wait/collect layer before adding any device-dependent coverage.

## Out Of Scope

- Concrete OSC/MIDI/UI producer bridges.
- Generic background drain loops.
- Multi-producer hot-swap arbitration.
- Session respawn for unsupported preserving swaps.
- Replacement `VoiceBinding` commit vocabulary.
- Repair/recovery after post-publish divergence.
