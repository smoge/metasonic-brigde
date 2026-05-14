# Module Organization Checkpoint

Date: 2026-05-08

This note records the current file-organization judgment before the next
scheduler work grows the compiler/runtime surface further.

## Current Assessment

`src/MetaSonic/Bridge/Compile.hs` has grown large enough that a split would now
help reviewability and future development. It is no longer just "final compile":
it contains several distinct layers:

- region formation,
- dense runtime representation,
- region-kernel selection,
- bus footprint and dependency views,
- scalar affine fusion,
- orchestration through `compileRuntimeGraph`.

The split should happen before deeper `4.E` scheduler work, because that work
will otherwise add more policy and dependency logic to an already crowded
module.

## Recommended Haskell Split

Keep `MetaSonic.Bridge.Compile` as the public facade first. It can re-export the
new internal modules so existing imports do not churn.

Proposed shape:

```text
MetaSonic.Bridge.Compile
  facade / orchestration / re-exports

MetaSonic.Bridge.Compile.Types
  RuntimeInput, FusedInput, RuntimeNode, RuntimeRegion,
  RuntimeGraph, RegionKernel, BusFootprint, tags

MetaSonic.Bridge.Compile.Regions
  RegionID, Region, RegionGraph, formRegions

MetaSonic.Bridge.Compile.RegionKernels
  selectRegionKernels, findKernelMatch, matches*

MetaSonic.Bridge.Compile.Dependencies
  runtimeNodeFootprint, regionFootprint,
  regionBusPrecedence, regionStructuralPrecedence, regionDependencies

MetaSonic.Bridge.Compile.Fusion
  fuseRuntimeGraph and affine-chain logic
```

This should be a mechanical, behavior-preserving refactor. Avoid changing
fusion, region selection, or scheduling semantics during the split.

## Other Files

`test/Spec.hs` is the largest file and is also due for a split eventually. A
reasonable future shape is:

- structural compiler tests,
- region and fusion tests,
- FFI/render-equivalence tests,
- template/MIDI/lifecycle properties.

That split is useful, but less urgent than `Compile.hs` unless test editing
starts slowing down review.

`tinysynth/rt_graph.cpp` is also large, but it is more tightly coupled: ABI
surface, runtime state, static helpers, DSP kernels, and lifecycle logic all
share internal types. Split it later and more carefully.

`app/Main.hs` could eventually separate demo registry, fusion survey, TUI, and
runner code. It is less load-bearing than `Compile.hs`.

## Recommended Next Step

Do a mechanical Haskell-only split of `Compile.hs`, keeping the public
`MetaSonic.Bridge.Compile` module stable. After that, return to the dynamic
bus-control policy and scheduler work.
