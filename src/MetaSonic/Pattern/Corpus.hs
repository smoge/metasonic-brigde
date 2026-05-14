-- |
-- Module      : MetaSonic.Pattern.Corpus
-- Description : Phase 6.A.2 — named pattern rows.
--
-- Each row is defensible as a musical idea independent of which
-- §4 / §5 gates it incidentally exercises. See [Phase 6.A.2
-- pattern corpus design]
-- (../../../notes/2026-05-10-g-phase-6a2-pattern-corpus-design.md)
-- for the contract and per-row hypotheses.

module MetaSonic.Pattern.Corpus
  ( -- * Corpus rows
    droneVibrato
  , arpeggioSendReturn
  , polyphonicStab
  , hotSwapEdit
  , layeredEnsemble
  , spectralFreezePad
    -- * Static event lists (exposed for tests and inspection)
  , droneVibratoEvents
  , arpeggioSendReturnEvents
  , polyphonicStabEvents
  , hotSwapEditEvents
  , layeredEnsembleEvents
  , spectralFreezePadEvents
    -- * Per-row template inputs (for Phase 6.A.3 corpus survey)
  , droneVibratoTemplates
  , arpeggioSendReturnTemplates
  , polyphonicStabTemplates
  , hotSwapEditTemplates
  , hotSwapEditAfterTemplates
  , layeredEnsembleTemplates
  , spectralFreezePadTemplates
    -- * Verification-gate reference range
  , corpusRange
  ) where

import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates (TemplateGraph,
                                             compileTemplateGraph)
import           MetaSonic.Pattern

-- | Compile or die. Corpus rows are fixed; a compile failure means
-- the row is malformed, which is a development-time error.
mustCompile :: [(String, SynthGraph)] -> TemplateGraph
mustCompile entries = case compileTemplateGraph entries of
  Right tg -> tg
  Left err -> error $ "Pattern.Corpus: compileTemplateGraph failed: " <> err

-- | The verification-gate reference range. Four seconds at 48 kHz.
corpusRange :: SampleRange
corpusRange = SampleRange (SamplePos 0) (SamplePos 192000)

----------------------------------------------------------------------
-- Row 1: drone-with-vibrato
--
-- Sine carrier with 5 Hz vibrato, LPF, scalar output gain, hardware
-- output. One long voice, periodic LPF-cutoff sweeps.

droneVibratoTemplates :: [(String, SynthGraph)]
droneVibratoTemplates = [("drone", droneVibratoGraph)]

droneVibrato :: Pattern
droneVibrato = Pattern
  { patternTemplates = mustCompile droneVibratoTemplates
  , patternEvents    = staticEvents droneVibratoEvents
  }

droneVibratoGraph :: SynthGraph
droneVibratoGraph = runSynth $ do
  lfo       <- sinOsc (Param 5.0)   (Param 0.0)
  vibBranch <- gain   lfo           (Param 10.0)
  vibFreq   <- add    vibBranch     (Param 440.0)
  carrier   <- sinOsc vibFreq       (Param 0.0)
  filtered  <- tagged "lpf"     (lpf  carrier  (Param 1500.0) (Param 4.0))
  shaped    <- tagged "outgain" (gain filtered (Param 0.5))
  out 0 shaped

droneVibratoEvents :: [(SamplePos, PatternEvent)]
droneVibratoEvents =
  [ (SamplePos 0,
       PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
         [ (ControlTag (MigrationKey "lpf")     0, 1500.0)
         , (ControlTag (MigrationKey "lpf")     1, 4.0)
         , (ControlTag (MigrationKey "outgain") 0, 0.5)
         ])
  , (SamplePos 48000,
       PEControlWrite (VoiceKey "v0") (ControlTag (MigrationKey "lpf") 0) 2000.0)
  , (SamplePos 96000,
       PEControlWrite (VoiceKey "v0") (ControlTag (MigrationKey "lpf") 0) 800.0)
  , (SamplePos 144000,
       PEControlWrite (VoiceKey "v0") (ControlTag (MigrationKey "lpf") 0) 1500.0)
  , (SamplePos 190000, PEVoiceOff (VoiceKey "v0"))
  ]

----------------------------------------------------------------------
-- Row 2: arpeggio-send-return
--
-- Voice template: saw + envelope-modulated gain → bus 5.
-- Fx template:    busIn 5 → LPF → scalar Gain → Out 0.
-- Two-note arpeggio plus one long-lived fx voice.

arpeggioSendReturnTemplates :: [(String, SynthGraph)]
arpeggioSendReturnTemplates =
  [ ("voice", arpVoiceGraph)
  , ("fx",    arpFxGraph)
  ]

arpeggioSendReturn :: Pattern
arpeggioSendReturn = Pattern
  { patternTemplates = mustCompile arpeggioSendReturnTemplates
  , patternEvents    = staticEvents arpeggioSendReturnEvents
  }

arpVoiceGraph :: SynthGraph
arpVoiceGraph = runSynth $ do
  saw    <- tagged "carrier"  (sawOsc (Param 220.0) (Param 0.0))
  envSig <- tagged "envelope" (env (Param 0.0) (Param 0.01) (Param 0.05)
                                    (Param 0.7) (Param 0.2))
  shaped <- gain saw envSig
  busOut 5 shaped

arpFxGraph :: SynthGraph
arpFxGraph = runSynth $ do
  source   <- busIn 5
  filtered <- tagged "lpf"     (lpf  source   (Param 1200.0) (Param 4.0))
  shaped   <- tagged "outgain" (gain filtered (Param 0.6))
  out 0 shaped

arpeggioSendReturnEvents :: [(SamplePos, PatternEvent)]
arpeggioSendReturnEvents =
  [ (SamplePos 0,
       PEVoiceOn (TemplateName "fx") (VoiceKey "fx0")
         [ (ControlTag (MigrationKey "lpf")     0, 1200.0)
         , (ControlTag (MigrationKey "outgain") 0, 0.6)
         ])
  , (SamplePos 0,
       PEVoiceOn (TemplateName "voice") (VoiceKey "v0") (noteOn 220.0))
  , (SamplePos 23000,
       PEControlWrite (VoiceKey "v0") gateTag 0.0)
  , (SamplePos 24000, PEVoiceOff (VoiceKey "v0"))
  , (SamplePos 24000,
       PEVoiceOn (TemplateName "voice") (VoiceKey "v1") (noteOn 329.63))
  , (SamplePos 47000,
       PEControlWrite (VoiceKey "v1") gateTag 0.0)
  , (SamplePos 48000, PEVoiceOff (VoiceKey "v1"))
  , (SamplePos 190000, PEVoiceOff (VoiceKey "fx0"))
  ]
  where
    gateTag = ControlTag (MigrationKey "envelope") 0
    noteOn freqHz =
      [ (ControlTag (MigrationKey "carrier") 0, freqHz)
      , (gateTag,                                1.0)
      ]

----------------------------------------------------------------------
-- Row 3: polyphonic-stab
--
-- Noise → LPF → envelope-modulated gain → Out 0.
-- 8 voices fire at t=0 and release at t=24000. The audio-modulated
-- Gain blocks RNoiseLpfGainOut per §4.B; the chain falls back to
-- per-node dispatch (the row's design-note hypothesis).

polyphonicStabTemplates :: [(String, SynthGraph)]
polyphonicStabTemplates = [("stab", stabGraph)]

polyphonicStab :: Pattern
polyphonicStab = Pattern
  { patternTemplates = mustCompile polyphonicStabTemplates
  , patternEvents    = staticEvents polyphonicStabEvents
  }

stabGraph :: SynthGraph
stabGraph = runSynth $ do
  noise    <- noiseGen
  filtered <- tagged "lpf"      (lpf noise (Param 800.0) (Param 6.0))
  envSig   <- tagged "envelope" (env (Param 0.0)  (Param 0.005)
                                      (Param 0.1) (Param 0.0)
                                      (Param 0.05))
  shaped   <- gain filtered envSig
  out 0 shaped

stabKeys :: [String]
stabKeys = ["s0","s1","s2","s3","s4","s5","s6","s7"]

polyphonicStabEvents :: [(SamplePos, PatternEvent)]
polyphonicStabEvents =
     [ (SamplePos 0,
          PEVoiceOn (TemplateName "stab") (VoiceKey k) stabInitial)
     | k <- stabKeys
     ]
  ++ [ (SamplePos 24000, PEVoiceOff (VoiceKey k))
     | k <- stabKeys
     ]
  where
    stabInitial =
      [ (ControlTag (MigrationKey "lpf")      0, 800.0)
      , (ControlTag (MigrationKey "envelope") 0, 1.0)
      ]

----------------------------------------------------------------------
-- Row 4: hot-swap-edit
--
-- Held sine drone (SinOsc → LPF → Out). A single PEHotSwap mid-
-- pattern installs a recompiled version with a different LPF
-- cutoff baseline; the carrier and LPF nodes carry the same
-- migration keys so §5.2 state migration preserves oscillator
-- phase across the swap.

hotSwapEditTemplates :: [(String, SynthGraph)]
hotSwapEditTemplates = [("drone", droneEditInitial)]

-- | Swap-target template list. The 'PEHotSwap' event in
-- 'hotSwapEditEvents' carries the compiled form of this list as its
-- payload. Exposed separately so the §6.A.3 corpus survey can scan
-- the post-swap shape too — without this, future drift in
-- 'droneEditAfter' would be invisible to the survey baseline.
hotSwapEditAfterTemplates :: [(String, SynthGraph)]
hotSwapEditAfterTemplates = [("drone", droneEditAfter)]

hotSwapEdit :: Pattern
hotSwapEdit = Pattern
  { patternTemplates = mustCompile hotSwapEditTemplates
  , patternEvents    = staticEvents hotSwapEditEvents
  }

droneEditInitial :: SynthGraph
droneEditInitial = runSynth $ do
  carrier  <- tagged "carrier" (sinOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 1500.0) (Param 2.0))
  out 0 filtered

droneEditAfter :: SynthGraph
droneEditAfter = runSynth $ do
  carrier  <- tagged "carrier" (sinOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 3000.0) (Param 2.0))
  out 0 filtered

hotSwapEditEvents :: [(SamplePos, PatternEvent)]
hotSwapEditEvents =
  [ (SamplePos 0,
       PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
         [(ControlTag (MigrationKey "lpf") 0, 1500.0)])
  , (SamplePos 96000,
       PEHotSwap (SwapLabel "edit-cutoff")
                 (mustCompile [("drone", droneEditAfter)]))
  , (SamplePos 190000, PEVoiceOff (VoiceKey "v0"))
  ]

----------------------------------------------------------------------
-- Row 5: layered-ensemble
--
-- bass (saw → LPF → env-gain → BusOut 5) and pad (paired detuned
-- sines → env-gain → BusOut 5) running concurrently through a
-- shared fx tail (BusIn 5 → LPF → scalar Gain → Out 0). Both voice
-- families have audio-modulated Gain, so per §4.B they stay on
-- per-node dispatch; the fx tail is a structural RBusInLpfGainOut
-- candidate (scalar Gain).

layeredEnsembleTemplates :: [(String, SynthGraph)]
layeredEnsembleTemplates =
  [ ("bass", bassGraph)
  , ("pad",  padGraph)
  , ("fx",   ensembleFxGraph)
  ]

layeredEnsemble :: Pattern
layeredEnsemble = Pattern
  { patternTemplates = mustCompile layeredEnsembleTemplates
  , patternEvents    = staticEvents layeredEnsembleEvents
  }

bassGraph :: SynthGraph
bassGraph = runSynth $ do
  saw      <- tagged "carrier"  (sawOsc (Param 55.0) (Param 0.0))
  filtered <- tagged "lpf"      (lpf saw (Param 400.0) (Param 4.0))
  envSig   <- tagged "envelope" (env (Param 0.0)  (Param 0.02)
                                      (Param 0.1) (Param 0.6)
                                      (Param 0.2))
  shaped   <- gain filtered envSig
  busOut 5 shaped

padGraph :: SynthGraph
padGraph = runSynth $ do
  s1     <- tagged "carrier"  (sinOsc (Param 220.0) (Param 0.0))
  s2     <- sinOsc (Param 220.5) (Param 0.0)
  summed <- add s1 s2
  envSig <- tagged "envelope" (env (Param 0.0) (Param 0.5)
                                    (Param 0.5) (Param 0.5)
                                    (Param 0.5))
  shaped <- gain summed envSig
  busOut 5 shaped

ensembleFxGraph :: SynthGraph
ensembleFxGraph = runSynth $ do
  source   <- busIn 5
  filtered <- tagged "lpf"     (lpf  source   (Param 2000.0) (Param 4.0))
  shaped   <- tagged "outgain" (gain filtered (Param 0.5))
  out 0 shaped

layeredEnsembleEvents :: [(SamplePos, PatternEvent)]
layeredEnsembleEvents =
  [ (SamplePos 0,
       PEVoiceOn (TemplateName "fx") (VoiceKey "fx0")
         [ (ControlTag (MigrationKey "lpf")     0, 2000.0)
         , (ControlTag (MigrationKey "outgain") 0, 0.5)
         ])
  , (SamplePos 0,
       PEVoiceOn (TemplateName "pad") (VoiceKey "p0")
         [ (ControlTag (MigrationKey "carrier")  0, 220.0)
         , (ControlTag (MigrationKey "envelope") 0, 1.0)
         ])
  , (SamplePos 0,
       PEVoiceOn (TemplateName "bass") (VoiceKey "b0")
         [ (ControlTag (MigrationKey "carrier")  0, 55.0)
         , (ControlTag (MigrationKey "envelope") 0, 1.0)
         ])
  , (SamplePos 48000,
       PEControlWrite (VoiceKey "b0")
         (ControlTag (MigrationKey "envelope") 0) 0.0)
  , (SamplePos 48000, PEVoiceOff (VoiceKey "b0"))
  , (SamplePos 48000,
       PEVoiceOn (TemplateName "bass") (VoiceKey "b1")
         [ (ControlTag (MigrationKey "carrier")  0, 73.42)
         , (ControlTag (MigrationKey "envelope") 0, 1.0)
         ])
  , (SamplePos 96000,
       PEControlWrite (VoiceKey "b1")
         (ControlTag (MigrationKey "envelope") 0) 0.0)
  , (SamplePos 96000, PEVoiceOff (VoiceKey "b1"))
  , (SamplePos 190000,
       PEControlWrite (VoiceKey "p0")
         (ControlTag (MigrationKey "envelope") 0) 0.0)
  , (SamplePos 190000, PEVoiceOff (VoiceKey "p0"))
  , (SamplePos 190000, PEVoiceOff (VoiceKey "fx0"))
  ]

----------------------------------------------------------------------
-- Row 6: spectral-freeze-pad
--
-- Sine drone → SpectralFreeze → scalar Gain → Out 0.
-- A long voice toggles the hop-latched freeze flag on and off so the
-- corpus exercises §6.D's first spectral kind through the pattern
-- contract without requiring a runtime pattern driver.

spectralFreezePadTemplates :: [(String, SynthGraph)]
spectralFreezePadTemplates = [("texture", spectralFreezePadGraph)]

spectralFreezePad :: Pattern
spectralFreezePad = Pattern
  { patternTemplates = mustCompile spectralFreezePadTemplates
  , patternEvents    = staticEvents spectralFreezePadEvents
  }

spectralFreezePadGraph :: SynthGraph
spectralFreezePadGraph = runSynth $ do
  carrier <- tagged "carrier" (sinOsc (Param 110.0) (Param 0.0))
  frozen  <- tagged "freeze"  (spectralFreeze carrier (Param 0.0))
  shaped  <- tagged "outgain" (gain frozen (Param 0.35))
  out 0 shaped

spectralFreezePadEvents :: [(SamplePos, PatternEvent)]
spectralFreezePadEvents =
  [ (SamplePos 0,
       PEVoiceOn (TemplateName "texture") (VoiceKey "sf0")
         [ (ControlTag (MigrationKey "carrier") 0, 110.0)
         , (freezeFlagTag,                         0.0)
         , (ControlTag (MigrationKey "outgain") 0, 0.35)
         ])
  , (SamplePos 48000,
       PEControlWrite (VoiceKey "sf0") freezeFlagTag 1.0)
  , (SamplePos 144000,
       PEControlWrite (VoiceKey "sf0") freezeFlagTag 0.0)
  , (SamplePos 190000, PEVoiceOff (VoiceKey "sf0"))
  ]
  where
    freezeFlagTag = ControlTag (MigrationKey "freeze") 1
