# App Main Split Recommendation

Date: 2026-05-08

`app/Main.hs` is worth splitting, but the split should be conservative. The
file is large enough that navigation is becoming expensive, yet it still has
clear internal boundaries. The goal should be to preserve behavior while moving
cohesive blocks into named modules.

Current shape:

- `app/Main.hs` is about 2,766 lines.
- The top half mixes demo graph definitions, CLI options, runtime dispatch,
  audio launch, inspection, and MIDI setup.
- The lower half is a substantial `--fusion-survey` subsystem: sink-shape
  scanning, survey rows, corpus definitions, schedule/rate/edge-rate tables,
  and formatting.

## Recommendation

Split in stages. Do not turn this into a broad cleanup pass.

The best first split is the `--fusion-survey` code. It is large, cohesive, and
mostly independent of the interactive runtime path. Moving it out would make
`Main.hs` much easier to scan without changing runtime behavior.

Suggested module sequence:

1. `MetaSonic.App.Demos`
   - Demo graph definitions.
   - `PolyMidiBindings`.
   - `DemoBody`, `Demo`, and `demoTable`.

2. `MetaSonic.App.Survey`
   - `SinkShape`.
   - `SurveyRow`.
   - Survey corpus.
   - Shape scanning.
   - Schedule/rate/edge-rate survey aggregation.
   - Survey table printers.
   - `runFusionSurvey`.

3. Keep `app/Main.hs` focused on:
   - CLI parsing.
   - Top-level mode dispatch.
   - Wiring demos to runners.

4. Optional later: `MetaSonic.App.Runtime`
   - `runSingleDemo`.
   - `runTemplateDemo`.
   - MIDI runner.
   - Audio bracket.
   - Trace/runtime summary printing.

## Why This Split

The survey code has become project infrastructure rather than executable glue.
It answers architecture questions for §4.B, §4.D, and §4.E. Keeping it inside
`Main.hs` makes the executable entrypoint carry too much of the compiler
research surface.

The demo definitions are also a natural module because both normal playback and
the survey consume them. Moving demos first or survey first would both be
reasonable, but survey-first probably gives the largest immediate reduction in
`Main.hs` complexity.

## Verification

After each extraction:

```sh
just stack-test
stack exec -- metasonic-bridge --fusion-survey
```

No C++ verification should be required unless the split changes runtime loading
or C++ source lists, which it should not.

## Non-Goals

- Do not redesign the CLI.
- Do not change survey output.
- Do not change demo graph behavior.
- Do not move compiler/library code just to satisfy the app split.
- Do not split everything in one patch.

The right first commit is a mechanical extraction with identical behavior.
