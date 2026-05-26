# Live Arbitration Gateway Manual Smoke — 2026-05-25

Status: passed. Manual operator smoke for the landed
`--manifest-live-session ... --live-arbitration-gateway` path.

This note records the first live-session run that exercised the
new live-app policy opt-in from the real CLI entrypoint. The goal was
not to add a new arbitration policy shape; it was to prove the
`Main` → `LiveAppReloadPolicy` → `RealReloadHostStackInputs` path
accepts the flag, opens a real live session, survives a preserving
reload, and keeps OSC ingress healthy before and after the reload.

## Invocation

```sh
PORT=17006 stack exec -- metasonic-bridge \
  --session-osc-port 17006 \
  --manifest-live-session examples/manifests/preserve-cutoff.json preserve-cutoff-dark \
  --strategy require-preserving \
  --live-arbitration-gateway
```

The `PORT=17006` environment binding was only operator context; the
binary consumed the explicit `--session-osc-port 17006` argument.

Fixture and route:

- Manifest: `examples/manifests/preserve-cutoff.json`
- Initial demo: `preserve-cutoff-dark`
- Reload target: `preserve-cutoff-bright`
- Strategy: `require-preserving`
- OSC port: `17006`
- Audio device: no explicit device selected; PortAudio used the host
  default output path
- MIDI ingress: off
- Live arbitration opt-in: `--live-arbitration-gateway`

ALSA / PortAudio device-probe stderr appeared before the initial
session open. It is not reproduced here because the load-bearing
result is that the live stack still reached `SessionOwnerReady`,
`audio running: yes`, and a clean EOF shutdown.

## What this smoke proves

The transcript proves the production `--manifest-live-session`
entrypoint accepts the `--live-arbitration-gateway` flag and remains
healthy under the resulting policy while running the same operator
flow as the existing require-preserving live-session smoke:

1. initial live stack opens and auto-starts the manifest voice;
2. OSC ingress opens on the requested port;
3. an OSC write is accepted before reload;
4. preflight succeeds for the target demo;
5. the supervised preserving reload commits;
6. no stopped-audio fallback is composed under `require-preserving`;
7. an OSC write is accepted after reload;
8. `status` reports the new plan and a healthy live stack;
9. EOF closes the session cleanly.

The transcript does not print an operator-visible
`arbitration gateway: on` row. Gateway enablement is pinned by the
source and tests: `Main` composes `withLiveArbitrationGateway
(optLiveArbitrationGateway opts)` into the live-app policy,
`withLiveArbitrationGateway True` sets
`LiveArbitrationProfile (Just defaultSessionArbitrationGatewayOptions)`,
and `projectLiveAppReloadPolicy` lowers that into
`sfsoArbitrationGatewayOptions`. The manual smoke closes the remaining
live-path sanity check: the real session path consumed the flag and
stayed healthy.

## Evidence per item

### 1. Session opened on the require-preserving route

```text
Manifest live session (Phase 8 v0).

  manifest path: examples/manifests/preserve-cutoff.json
  strategy:      require-preserving
  route:         supervised (require-preserving; reloadSupervised + HostStackFactory)
  initial demo:  preserve-cutoff-dark
```

### 2. Initial stack and ingress were healthy

```text
initial: auto-starting one instance per template...
  drone -> enqueued CmdVoiceOn (TemplateName {unTemplateName = "drone"}) (VoiceKey {unVoiceKey = "v0"}) []
initial fan-in:
  audio running: yes
  queue depth: 0
  owner status: SessionOwnerReady
  reload status: SessionFanInNormalOperation
  active voices: 1
ingress: open demo=preserve-cutoff-dark ui-controls=1 osc-controls=1 midi-cc=1 defaultVoice=v0 oscPort=17006 midi=off
addressable OSC surface:
  /v0/lpf/0  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)
```

### 3. Pre-reload OSC write was accepted

```text
osc accept: /v0/lpf/0 name="cutoff" value=1800
```

This was the pre-reload write to the dark plan's cutoff target.

### 4. Reload preflight succeeded

```text
> demo:preserve-cutoff-bright
preflight events:
  - preflight started: "preserve-cutoff-bright"
  - preflight succeeded: "preserve-cutoff-bright"
```

### 5. Preserving reload committed

```text
supervised outcome: committed (new plan installed)
reload events:
  - preserving phase started
  - preserving phase committed
retired bindings:
  (none)
supervisor events:
  - in-window: started
  - in-window: committed
resource timeline:
  - in-window reload committed
  - serving plan: preserve-cutoff-bright
```

### 6. No stopped-audio fallback was composed

No `stopped-audio phase` lines appeared in the transcript. Under
`require-preserving`, that absence is load-bearing: it shows the
run did not compose with stopped-audio fallback.

### 7. Post-reload OSC write was accepted

```text
osc accept: /v0/lpf/0 name="cutoff" value=900
```

This was the post-reload write against the bright plan after the
supervised commit.

### 8. Status showed the bright plan and a healthy stack

```text
> status

status:
  current plan demo: preserve-cutoff-bright
    fan-in:
  audio running: yes
  queue depth: 0
  owner status: SessionOwnerReady
  reload status: SessionFanInNormalOperation
  active voices: 1
  ingress:           open demo=preserve-cutoff-bright ui-controls=1 osc-controls=1 midi-cc=1 defaultVoice=v0 oscPort=17006 midi=off
  last outcome:      committed (new plan installed)
```

### 9. Session closed cleanly on EOF

```text
(EOF; closing session.)
```

## Non-goals

- This smoke does not exercise `ProducerPriority` or `TargetClaim`;
  those richer arbitration shapes still require structured input and
  remain use-case gated.
- This smoke does not prove a policy rejection path. The selected
  opt-in is the default `FifoOnly` gateway, so accepted writes should
  preserve the existing FIFO behavior.
- This smoke does not add an operator-visible gateway status row. If
  that becomes useful, it should be added deliberately as UI contract,
  not just to make this note easier to prove.
- This smoke does not cover MIDI ingress; the run had `midi=off`.

## Follow-up

The sibling wrapper landed in `903daf5` as
`tools/manifest_live_session_arbitration_gateway_smoke.sh`. It is the
repeatable counterpart to this manual evidence: passes
`--live-arbitration-gateway`, defaults to port `17006`, and reuses
the same acceptance markers. The `just`-discoverable form is
`just manifest-live-session-arbitration-gateway-smoke N`; the recipe
also accepts `port=N` for compatibility with the original comment. The
no-gateway require-preserving wrapper
(`tools/manifest_live_session_require_preserving_smoke.sh`) remains
the deliberate no-gateway baseline and is not extended in place.

- route line;
- `audio running: yes`;
- `oscPort=PORT`;
- pre-reload `value=1800`;
- `supervised outcome: committed`;
- preserving phase started / committed;
- absence of `stopped-audio phase`;
- post-reload `value=900`;
- status showing `current plan demo: preserve-cutoff-bright`;
- clean EOF / process exit.

### Wrapper validation

The `just` recipe and wrapper were validated after the recipe learned
to normalize both positional `N` and compatibility `port=N` forms:

```sh
just manifest-live-session-arbitration-gateway-smoke port=17006
```

The run built the executable, launched the wrapper with
`PORT=17006`, observed every acceptance marker, released the UDP
port, and exited 0:

```text
=== marker checks ===
  [ok]   1.  supervised require-preserving session route
  [ok]   2a. audio running
  [ok]   2b. OSC ingress bound on configured port
  [ok]   3.  pre-reload OSC accept (value=1800)
  [ok]   4a. supervised outcome committed
  [ok]   4b. preserving phase started
  [ok]   4c. preserving phase committed
  [ok]   4d. no stopped-audio phase (no fallback composition)
  [ok]   5a. post-reload status shows current plan = new demo
  [ok]   5b. post-reload OSC accept (value=900)
  [ok]   6a. session exit 0
  [ok]   6b. ss snapshot clean (no listener)
  [ok]   6c. active bind probe rebound port

=== SMOKE PASSED ===
All acceptance markers observed.
  transcript: /tmp/manifest-live-session-arbitration-gateway-transcript.txt
  probe log:  /tmp/manifest-live-session-arbitration-gateway-probe.txt
```

Do not extend this into richer arbitration policy mutation until a
concrete caller needs structured policy input.

## Related artifacts

| Artifact | Symbol / anchor |
| --- | --- |
| `app/Main.hs` | `ManifestLiveSession` dispatch, `optLiveArbitrationGateway` |
| `app/MetaSonic/App/ManifestLivePolicy.hs` | `withLiveArbitrationGateway`, `projectLiveAppReloadPolicy` |
| `test/MetaSonic/Spec/AppManifestLivePolicy.hs` | live arbitration gateway policy/projection tests |
| `tools/manifest_live_session_require_preserving_smoke.sh` | existing wrapper pattern for repeatable live-session evidence |
| `examples/manifests/preserve-cutoff.json` | blessed preserving fixture used by this smoke |
| `notes/2026-05-25-i-live-app-manifest-reload-policy.md` | policy boundary and axis 4 opt-in closeout |
