## GHC 9.12.4 Stack Nightly Upgrade

Date: 2026-05-25

Status: decision note + validation log. The main Stack resolver has
been moved from the GHC 9.10.3 LTS 24 baseline to
`nightly-2026-05-25`, which uses GHC 9.12.4. This is a deliberate
early-compatibility move, not an adoption of new language features as
a design dependency.

## Why this is useful

GHC 9.12 is now far enough along to be worth testing in the main
development loop. The 9.12 series brings useful language and tooling
changes, including `OrPatterns`, `MultilineStrings`, `NamedDefaults`,
improvements around `OverloadedRecordDot`, and the object-code
determinism flag. None of those features are required for the current
Phase 8 work, but having the project build on the newer compiler keeps
the codebase from drifting behind the active compiler line.

GHC 9.12.4 is also a bug-fix release on top of the 9.12 line. That
matters more for this repository than the syntax additions: MetaSonic
mixes a large Haskell test suite with C++ FFI objects, threaded tests,
and audio/runtime boundary code. Compiler and code-generation fixes
are relevant even when no source-level feature is adopted.

The local Stack version is already recent enough for this experiment
(`stack 3.9.3` was observed locally), so this is not blocked on a
tool upgrade.

## Why this is a tradeoff

The current LTS line is still GHC 9.10.3. Moving to
`nightly-2026-05-25` means leaving the LTS package set for a Nightly
snapshot. That is acceptable for this project right now only if the
resolver change is treated as a compatibility checkpoint:

* do not start using GHC 9.12-only syntax until the build and test
  suite are clean;
* keep package fixes narrow and explicit if dependencies need
  adjustment;
* keep the old LTS 24.41 snapshot URL in `stack.yaml` as the rollback
  anchor while the migration is being validated;
* update README wording to claim the new compiler only after the
  build and test validation is complete.

## Observed validation: 2026-05-25

The initial validation passed under GHC 9.12.4:

```sh
stack build
stack test
```

`stack test` reported all 1555 tests passed.

The first 9.12.4 test build surfaced a package metadata warning:
`MetaSonic.Spec.AppManifestLiveCommonRetiredBindings` and
`MetaSonic.Spec.AppManifestLiveCommonStaleByReload` were imported by
`test/Spec.hs` but omitted from the test-suite `other-modules` list.
The resolver slice fixes that in `package.yaml`; the generated
`metasonic-bridge.cabal` was refreshed by Stack/hpack.

## Candidate feature uses

The source scan did not find a project-wide reason to make GHC 9.12
features part of the Phase 8 implementation style yet. The useful
spots are narrow:

* `OrPatterns` fits the small command-alias parsers that currently
  duplicate outcomes for synonymous strings, especially
  `parseLiveSessionCommand` in
  `app/MetaSonic/App/ManifestLiveSession.hs` and
  `parseManifestReloadHostStrategy` in
  `app/MetaSonic/App/ManifestReloadCli.hs`.
* `MultilineStrings` could make future CLI help-text edits less
  noisy in `app/Main.hs`, where the usage text is assembled from many
  adjacent string fragments. The dynamic parts of that help output
  still need ordinary composition, so this is only worth doing when
  the help text is already being touched.
* The object-code determinism flag is more useful as a build/release
  experiment than as a source refactor. It belongs in a separate
  reproducibility check if artifact comparison becomes important.
* `NamedDefaults` and the `OverloadedRecordDot` improvements do not
  have an obvious local payoff from the current code scan. Adopting
  them now would be stylistic churn.

## Non-goals

This upgrade is not a reason to refactor the DSL, change the runtime
ABI, or adopt new extensions in active Phase 8 implementation code.
New 9.12 features can be evaluated later after the resolver move is
boring.

It also does not replace the planned test-harness grouping cleanup.
That cleanup should remain a separate harness-only commit after the
compiler/resolver change is either verified or rolled back.

## References

* GHC 9.12.1 release announcement:
  <https://www.haskell.org/ghc/blog/20241216-ghc-9.12.1-released.html>
* GHC 9.12.4 release announcement:
  <https://www.haskell.org/ghc/blog/20260327-ghc-9.12.4-released.html>
* Stackage snapshot listing:
  <https://www.stackage.org/snapshots>
