# Session Megafile Split Recap

Date: 2026-05-18

Status: closure note for the twenty-two-commit arc that split
`test/MetaSonic/Spec/Session.hs` from a 5352-line parent into
twenty-two focused `MetaSonic.Spec.Session.*` submodules plus the
shared `MetaSonic.Spec.SessionShared` helper module. The parent
module is now gone; the structural work is in a rest state.

## Why

`MetaSonic.Spec.Session` had become the long-lived staging ground
for the whole session-prep stack: command vocabulary, resolve
rebuilds, owner/step state, RTGraph adapter installation and
hot-swap, producer queues, arbitration, Pattern running, host
serialization, preserving hot-swap, fan-in, service draining, UI,
and OSC ingress. The file was no longer one conceptual spec. A
failure in an OSC listener loopback test and a failure in Prep B/C
state admission both pointed at the same 5000-line parent.

The split was mechanical. The goal was to preserve the existing
test groups and move each cohort to the module that names the
behavior it protects, while leaving shared test fixtures in one
explicit helper module instead of hiding them in a parent megafile.

## Final structure

`test/MetaSonic/Spec/Session.hs` has been deleted. The final
registered `MetaSonic.Spec.Session.*` test surface is:

| Module                                          | Group label                                             | Cases |
|-------------------------------------------------|---------------------------------------------------------|-------|
| `MetaSonic.Spec.Session.Command`                | `Session Prep A: command vocabulary`                    | 5     |
| `MetaSonic.Spec.Session.Resolve`                | `Session Prep A: resolve rebuild`                       | 5     |
| `MetaSonic.Spec.Session.Report`                 | `Session Prep A: lifecycle reports`                     | 4     |
| `MetaSonic.Spec.Session.State`                  | `Session Prep B/C: admission, commits, and handshake`   | 20    |
| `MetaSonic.Spec.Session.Step`                   | `Session Prep D: runtime adapter shell`                 | 9     |
| `MetaSonic.Spec.Session.ControlTarget`          | `Session Prep E: control target resolver`               | 5     |
| `MetaSonic.Spec.Session.RTGraphAdapterInstall`  | `Session Prep E: RTGraph adapter install`               | 11    |
| `MetaSonic.Spec.Session.RTGraphAdapterHotSwap`  | `Session Prep E: RTGraph adapter hot-swap`              | 9     |
| `MetaSonic.Spec.Session.Owner`                  | `Session Prep F: runtime owner`                         | 9     |
| `MetaSonic.Spec.Session.Queue`                  | `Session Prep G: producer queue`                        | 8     |
| `MetaSonic.Spec.Session.Arbitration`            | `Session producer arbitration policy`                   | 6     |
| `MetaSonic.Spec.Session.ArbitrationGateway`     | `Session producer arbitration gateway`                  | 4     |
| `MetaSonic.Spec.Session.PatternProducer`        | `Session Prep H: Pattern producer`                      | 14    |
| `MetaSonic.Spec.Session.Runner`                 | `Session Prep I: scripted runner`                       | 4     |
| `MetaSonic.Spec.Session.Host`                   | `Session Prep J: Pattern session host`                  | 4     |
| `MetaSonic.Spec.Session.PreservingHotSwap`      | `Session Prep L: preserving hot-swap semantics`         | 4     |
| `MetaSonic.Spec.Session.LiveHotSwap`            | `Session Prep O: live preserving hot-swap orchestration` | 8     |
| `MetaSonic.Spec.Session.FanInHost`              | `Session Prep P: producer fan-in host`                  | 5     |
| `MetaSonic.Spec.Session.FanInService`           | `Session fan-in drain service`                          | 11    |
| `MetaSonic.Spec.Session.UIProducer`             | `Session UI producer adapter`                           | 9     |
| `MetaSonic.Spec.Session.OSCProducer`            | `Session OSC producer adapter`                          | 9     |
| `MetaSonic.Spec.Session.OSCListener`            | `Session OSC listener adapter`                          | 8     |

The table totals 171 Session cases. The full suite remains at
1141 tests; no test was deliberately added or removed by the
extraction arc.

`MetaSonic.Spec.SessionShared` is now the shared test-helper
surface. Its exported helpers are:

- Producer / queue conveniences: `testProducer`, `queueOrFail`,
  `enqueueOrFail`, `fanInQueuedOrFail`, `gatewayQueuedOrFail`.
- Pattern-runner fixtures: `patternProducerOrFail`,
  `missingVoiceEvents`, `missingVoiceEventsAt`.
- RTGraph / template fixtures: `totalTemplateNodes`,
  `withInstalledAdapter`, `duplicateFirstTwoTemplates`,
  `compileTemplateGraphOrFail`, `constantAdapter`.
- Shared control tags: `freqTag`, `levelTag`.

## Line-count trajectory

The parent line-count path was:

| Checkpoint                                           | Parent lines |
|------------------------------------------------------|--------------|
| Before `0714db7` (`sessionCommandTests` extraction)  | 5352         |
| After `cd89afc` (`State`)                            | 4775         |
| After `5805c61` (`PatternProducer`)                  | 2669         |
| After `017eb12` (`PreservingHotSwap`)                | 2120         |
| After `217963b` (`FanInService`)                     | 1073         |
| After `6ddb15c` (`UIProducer`)                       | 748          |
| After `6c17f7d` (`OSCProducer`)                      | 433          |
| After `7daf7bf` (`OSCListener`, parent deletion)     | 0            |

The apparent total Session test line count did not shrink by the
same amount because the submodules carry explicit imports, local
module headers, and helper-placement comments that were previously
implicit in the open-import parent.

## Design decisions worth recording

**The parent was deleted instead of kept as an aggregator.** Unlike
the FFI split, there was no cross-cutting opener cohort left in
`MetaSonic.Spec.Session`. `test/Spec.hs` already registers each
`TestTree` directly, so retaining a parent module would have been
only a breadcrumb. Exact parent references were removed from
`package.yaml`, `metasonic-bridge.cabal`, and `test/Spec.hs`.

**`SessionShared` is the shared test fixture home.** Helpers moved
there only when more than one extracted cohort needed them. That is
why the module contains both low-level queue assertions
(`queueOrFail`, `enqueueOrFail`) and higher-level RTGraph fixtures
(`withInstalledAdapter`, `constantAdapter`). This keeps the test
modules one-export clean without creating a fleet of tiny helper
modules during a mechanical split.

**Test-tree paths were preserved.** The extracted modules keep the
same top-level `testGroup` labels, and the old parent was not itself
a Tasty group. Selector paths that use labels such as
`Session Prep G: producer queue`, `Session fan-in drain service`,
or `Session OSC listener adapter` should continue to work. Some
labels never carried a `Prep X:` prefix in the parent — arbitration,
fan-in service, and the UI/OSC adapters keep that asymmetry. The
drift is code-navigation drift only: source references now point to
`MetaSonic.Spec.Session.<Cohort>` instead of the deleted parent.

**One `TestTree` per submodule.** Each extracted module exports only
its cohort `TestTree`. Private helpers stayed local, including
`testUIProducerOptions` in `UIProducer` and
`isSessionParseFailure` in `OSCListener`.

**No parent breadcrumbs remain.** The deleted parent does not carry
section-comment anchors to the extracted modules. The command
`git log -- test/MetaSonic/Spec/Session.hs` is the historical map,
and `test/Spec.hs` plus `package.yaml` are the live registry.

## Open follow-up

There is no forced helper-placement follow-up. Revisit
`SessionShared` only if a future session cohort makes the surface
too broad to scan or if a helper naturally belongs in a narrower
domain-specific test module. Until then, the split is closed.
