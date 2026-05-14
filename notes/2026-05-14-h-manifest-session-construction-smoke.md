# Manifest Session Construction Smoke

Date: 2026-05-14

Status: implemented as a non-audio CLI smoke for the construction-time
manifest session path.

## Summary

`--manifest-session-smoke MANIFEST.json DEMO` is the first app-visible
path that takes an external authoring manifest all the way to a fresh
`SessionOwner`.

It deliberately remains construction-time only:

```text
AuthoringManifestDoc JSON
  -> built-in authored-demo reload catalog
  -> ManifestReloadPlan
  -> constructManifestSessionFromPlan
  -> SessionOwner status / installed graph summary
```

It does not start audio, step `CmdHotSwap`, enqueue producer commands,
replace an existing owner, migrate voices, or claim live reload
semantics.

## Why This Exists

The previous manifest CLI modes proved two separate things:

- `--manifest-reload-plan DEMO` proved that the built-in app catalog can
  produce a manifest reload plan and print it.
- `--manifest-reload-plan-file MANIFEST.json DEMO` proved that an
  external JSON manifest can decode, validate against the built-in
  authored-demo catalog, and produce the same diagnostic plan.

The library already had the construction helper:

```haskell
constructManifestSessionFromPlan
  :: ManifestReloadPlan
  -> SessionOwnerOptions
  -> (SessionOwner -> IO a)
  -> IO (Either SessionAdapterSetupIssue a)
```

The missing app-facing proof was that the external JSON path can feed
that helper and produce a real fresh owner. The smoke closes that gap
without starting the stopped-audio or live-reload design.

## CLI Contract

```sh
metasonic-bridge --manifest-session-smoke MANIFEST.json DEMO
```

The command:

1. Reads `MANIFEST.json` using the existing
   `decodeManifestDoc` decoder.
2. Resolves `DEMO` through the normal demo-target resolver.
3. Requires the selected demo to have authoring metadata.
4. Builds the built-in authored-demo manifest reload catalog from
   `demoTable`.
5. Plans with `planManifestReload`, default resource policy, and
   `SwapLabel ("manifest:" <> demoKey demo)`.
6. Constructs a fresh owner with `constructManifestSessionFromPlan plan
   defaultSessionOwnerOptions`.
7. Reads `sessionOwnerState` and `sessionOwnerStatus`.
8. Prints a construction smoke summary and exits.

The output intentionally overlaps with the diagnostic plan output:
template count, template names, resource policy projection, owner
status, whether the installed graph matches the plan, active voice
count, and explicit `audio started: no` / `command projection: not
executed` lines.

## Runtime Boundary

The construction helper calls `withSessionOwner` with:

- `mrlpTemplateGraph plan` as the initial graph;
- `manifestSessionOwnerOptions defaultSessionOwnerOptions plan` as the
  owner options.

That means the owner starts with the graph already installed as its
initial state. No `CmdHotSwap` is needed or executed during
construction.

This is different from reload:

- Stopped-audio reload would need an existing owner, interruption
  semantics, producer-drain/rejection policy, failure recovery, and a
  decision about whether the old owner remains valid after failure.
- Preserving hot-swap would need the existing live migration protocol,
  execution-time preservation checks, generation wait, retired-stat
  verification, and divergence policy on post-publish uncertainty.
- Host teardown/rebuild would need ownership rules for external
  producers, queued commands, active voices, and device/session
  lifetime.

The smoke chooses none of those strategies.

## Failure Surface

Failures remain intentionally narrow and observable:

- file read errors report the manifest path;
- JSON/schema errors come from `decodeManifestDoc`;
- manifest/catalog mismatch, missing demo, duplicate rows, bad roles,
  missing templates, and invalid resource policy come from
  `planManifestReload`;
- construction failures are reported as
  `Manifest session construction failed: ...`, directly reflecting the
  `withSessionOwner` / RTGraph adapter setup issue.

There is no new recovery policy. The command exits after reporting the
failure.

## Test Coverage

`test/MetaSonic/Spec/AppDemos.hs` now covers the app-level path:

1. Build an external manifest JSON document from the authored
   `send-return` catalog entry.
2. Decode it through `decodeManifestDoc`.
3. Plan through the built-in authored-demo catalog.
4. Construct a fresh owner with `constructManifestSessionFromPlan`.
5. Assert that the owner's `SessionState` graph matches the catalog
   graph and the owner status is `SessionOwnerReady`.

Manual CLI smoke uses the same path:

```sh
stack exec -- metasonic-bridge --authoring-manifest send-return \
  > /tmp/metasonic-send-return-manifest.json

stack exec -- metasonic-bridge \
  --manifest-session-smoke /tmp/metasonic-send-return-manifest.json send-return
```

## Non-Goals

This slice must not add:

- audio startup;
- `CmdHotSwap` execution;
- stopped-audio clear/rebuild;
- preserving live hot-swap;
- session fan-in or producer queue drain;
- GUI toolkit integration;
- manifest-owned arbitration policy;
- app-level catalog selection beyond the built-in diagnostic catalog;
- repair/recovery after construction failure.

The next serious reload step should still be a design note comparing
stopped-audio reload, preserving hot-swap, and host teardown/rebuild
before any implementation chooses one.
