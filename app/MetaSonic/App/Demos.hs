module MetaSonic.App.Demos
  ( simpleGraph
  , chainGraph
  , fanOutGraph
  , sawGraph
  , noiseGraph
  , noiseLpfGraph
  , filteredSawGraph
  , detunedSawGraph
  , ringModGraph
  , fmGraph
  , envPluckGraph
  , intermodGraph
  , PolyMidiBindings (..)
  , midiPolySynth
  , sendReturnVoice
  , sendReturnFx
  , sendReturnDemo
  , DemoBody (..)
  , Demo (..)
  , demoTable
    -- * Phase 8.G: authoring metadata reporting
  , namedControlGraph
  , namedControlAuthoring
  , sendReturnAuthoring
  ) where

import           Data.Word                 (Word8)

import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Report (AuthoringReport,
                                             addReportedControl,
                                             emptyAuthoringReport,
                                             ensembleReport)
import qualified MetaSonic.Authoring.Report as Report
import           MetaSonic.Bridge.Source

simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

sawGraph :: SynthGraph
sawGraph = runSynth $ do
  osc <- sawOsc 440.0 0.0
  g   <- gain osc 0.4
  out 0 g

noiseGraph :: SynthGraph
noiseGraph = runSynth $ do
  n <- noiseGen
  g <- gain n 0.15
  out 0 g

-- noise through a lowpass filter.
noiseLpfGraph :: SynthGraph
noiseLpfGraph = runSynth $ do
  n <- noiseGen
  f <- lpf n 800.0 0.7
  g <- gain f 0.4
  out 0 g

-- low saw through a slightly resonant lpf
-- q > 1 results in a peak at the cutoff
filteredSawGraph :: SynthGraph
filteredSawGraph = runSynth $ do
  osc <- sawOsc 110.0 0.0
  f   <- lpf osc 1200.0 1.5
  g   <- gain f 0.6
  out 0 g

-- two detuned saws summed onto bus 0
-- 0.5 Hz offset creates a slow beating effect
detunedSawGraph :: SynthGraph
detunedSawGraph = runSynth $ do
  osc1 <- sawOsc 220.0 0.0
  osc2 <- sawOsc 220.5 0.5     --  phase offset avoids phase cancellation
  g1   <- gain osc1 0.3
  g2   <- gain osc2 0.3
  out 0 g1
  out 0 g2                     -- second out accumulates onto same bus

-- Stereo detuned-saw patch authored through MetaSonic.Authoring.
-- Two slightly-offset saws are panned into a stereo image, mixed as
-- a Stereo pair, scaled, and written with the Phase 8.D 'stereoOut'
-- routing alias. The lowered graph is still ordinary Gain/Add/Out
-- nodes, so compiler and inspector tools stay transparent.
authoringStereoSawGraph :: SynthGraph
authoringStereoSawGraph = runSynth $ do
  l <- sawOsc 220.0 0.0
  r <- sawOsc 220.5 0.5
  leftVoice  <- Auth.pan2 (Auth.mono l) (-0.45)
  rightVoice <- Auth.pan2 (Auth.mono r)   0.45
  stereoSig  <- Auth.addS leftVoice rightVoice
  master     <- Auth.gainS stereoSig (Param 0.3)
  Auth.stereoOut 0 master

-- Phase 8.C2 showcase: a stereo fx chain authored entirely through
-- the lifted helpers. Shape goes
-- 'stereoSrc -> hpfS -> envS -> delayS -> gainS -> stereoOut',
-- and the lowered graph still inspects as ordinary 'KHPF / KEnv /
-- KGain / KDelay / KOut' nodes — 8.C2 only removes per-channel
-- boilerplate, not primitive visibility.
authoringStereoFxChainGraph :: SynthGraph
authoringStereoFxChainGraph = runSynth $ do
  l    <- sawOsc 110.0 0.0
  r    <- sawOsc 110.5 0.5
  let src = Auth.stereo l r
  filt <- Auth.hpfS   src  (Param 200.0) (Param 0.7)
  amped <- Auth.envS  filt
             (Param 1.0)    -- always-on gate
             (Param 0.02)   -- attack
             (Param 0.25)   -- decay
             (Param 0.7)    -- sustain
             (Param 0.6)    -- release
  delayed <- Auth.delayS 0.4 amped (Param 0.18)
  master  <- Auth.gainS delayed (Param 0.25)
  Auth.stereoOut 0 master

-- Ring modulation: 440 Hz carrier multiplied sample-by-sample by a 7 Hz
-- modulator. Both signals are bipolar, so this is genuine ring mod
-- (sum/difference frequencies) rather than amplitude modulation.
-- Final 0.3 gain stage keeps the output at a reasonable level.
ringModGraph :: SynthGraph
ringModGraph = runSynth $ do
  carrier   <- sinOsc 440.0 0.0
  modulator <- sinOsc 7.0 0.0
  ring      <- gain carrier modulator
  amped     <- gain ring 0.3
  out 0 amped

-- Vibrato: a 5 Hz LFO biased by 440 Hz drives the carrier's
-- frequency between 410 and 470 Hz. Demonstrates the full bias-and-
-- scale pattern: gain to set deviation depth, add to set the center.
fmGraph :: SynthGraph
fmGraph = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 30.0           -- ±30 Hz
  freq      <- add 440.0 deviation
  carrier   <- sinOsc freq 0.0
  amped     <- gain carrier 0.3
  out 0 amped

-- Plucked-tone shape: an ADSR envelope with gate held high (Param 1)
-- shapes a 220 Hz sine. Attack 5 ms, decay 200 ms, sustain 0.0
-- (linear) makes the envelope fade to silence after the percussive
-- hit. Release time is unused while the gate is held, but is set to
-- 100 ms for completeness.
envPluckGraph :: SynthGraph
envPluckGraph = runSynth $ do
  e     <- env 1.0 0.005 0.2 0.0 0.1
  tone  <- sinOsc 220.0 0.0
  amped <- gain tone e
  scale <- gain amped 0.5
  out 0 scale

-- | Intermodulation showcase: a pulse voice with slow PWM, then a
-- band-pass that drifts through the spectrum. 'pulseOsc' reads width
-- sample-by-sample, so the PWM is genuinely audio-rate. 'bpf' reads
-- cutoff once per block, which is fine for this slow 0.3 Hz sweep.
-- For faster MIDI/UI cutoff changes, put 'smooth' before the cutoff
-- input to glide between blocks; within-block filter sweeps would
-- need a sample-accurate filter kernel.
intermodGraph :: SynthGraph
intermodGraph = runSynth $ do
  -- LFO 1 (PWM): triangle at 0.7 Hz, scaled+offset to [0.15, 0.85]
  -- so the pulse never fully collapses to silence at either extreme.
  lfo1   <- triOsc 0.7 0.0
  lfo1s  <- gain lfo1 0.35      -- ±0.35
  width  <- add  lfo1s 0.5      -- [0.15, 0.85]
  -- LFO 2 (filter sweep): sine at 0.3 Hz, biased to ~ [400, 2000] Hz.
  lfo2   <- sinOsc 0.3 0.0
  lfo2s  <- gain lfo2 800.0     -- ±800 Hz
  cutoff <- add  lfo2s 1200.0   -- [400, 2000]
  -- Voice: 220 Hz pulse with the modulated width.
  voice  <- pulseOsc 220.0 0.0 width
  -- BPF with audio-rate cutoff and a moderately resonant Q.
  filt   <- bpf voice cutoff 4.0
  master <- gain filt 0.4
  out 0 master

-- | Captured Connections + control indices for a poly synth template
-- whose voice / CC / pitch-bend inputs the live-MIDI demo runner
-- needs to bind. Each tuple is @(target_node, control_index)@; the
-- runner resolves @target_node@ to a dense 'NodeIndex' post-compile
-- via 'connectionNodeID' + 'resolveNodeIndex'.
data PolyMidiBindings = PolyMidiBindings
  { pmbFreq      :: !(Connection, Int)
  , pmbGate      :: !(Connection, Int)
  , pmbVelocity  :: !(Maybe (Connection, Int))
  , pmbCCs       :: ![(Word8, Connection, Int, Float, Float)]
    -- ^ @(cc_number, target, control_index, min, max)@.
  , pmbPitchBend :: !(Maybe (Connection, Int, Float))
    -- ^ @(target, control_index, semitone_range)@.
  }

-- A poly synth template for the live-MIDI demo. The producer thread
-- (driven by tinysynth/midi_demo.cpp) writes per-voice freq into the
-- sine's freq control on note-on, gate=1 into the env's gate control,
-- and CC 7 into a smoothed master-volume parameter. Pitch-bend
-- rewrites the sine's freq control. Note-offs trigger the env's
-- release segment via VoiceAllocator, which delivers a click-free
-- fade.
--
-- The 'cc' builder auto-inserts a Smooth at control ingress and
-- records the binding internally — see §1.7 — so we don't need a
-- parallel manual entry in 'pmbCCs'.
midiPolySynth :: SynthM PolyMidiBindings
midiPolySynth = do
  osc    <- sinOsc 220.0 0.0
  e      <- env 0.0 0.005 0.2 0.5 0.1
  amped  <- gain osc e
  vol    <- cc 7 0.3 0.0 1.0                -- CC 7 -> smoothed [0, 1]
  master <- gain amped vol
  _      <- out 0 master
  pure PolyMidiBindings
    { pmbFreq      = (osc, 0)
    , pmbGate      = (e,   0)
    , pmbVelocity  = Nothing
    , pmbCCs       = []                     -- 'cc' handled CC 7
    , pmbPitchBend = Just (osc, 0, 2.0)
    }

{- Note [sendReturnDemo: cross-template send/return]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The first and (so far) only multi-template demo. Two MetaDefs share
one Server-global bus pool: the "voice" template writes a vibrato
saw to bus 7, and the "fx" template reads bus 7, low-pass filters it,
and routes the result to hardware bus 0. This is the canonical
"synth + FX send/return" pattern that single-template graphs cannot
express — putting the LPF inside the voice would couple them, and
sharing an LPF across N voices is exactly what motivates the
template-level abstraction.

What this demonstrates concretely:

  - Two SynthGraphs compiled independently into RuntimeGraphs.
  - compileTemplateGraph derives bus footprints (voice writes {7},
    fx reads {7}) and topologically sorts: voice precedes fx in
    'tgTemplates'. The runtime processes templates in that order
    every block, so by the time fx's BusIn(7) reads, voice's
    BusOut(7) has already accumulated this block's contribution.
  - loadTemplateGraph spawns one instance per template
    automatically, so a typical "one voice + one FX" ensemble works
    without explicit instance management.

The voice template uses the 'add'/'gain' bias-and-scale idiom from
fmGraph for vibrato (LFO → ±8 Hz deviation around 110 Hz). The fx
template is intentionally minimal (just an LPF) — the point is the
cross-template plumbing, not DSP cleverness.
-}

-- The voice and fx templates are authored through the Phase
-- 8.E ensemble builder: 'busNamed "main-send"' allocates the
-- shared bus deterministically, and both templates pick up
-- that handle through ordinary closure capture inside the
-- 'voice' / 'fx' blocks. The compiled 'TemplateGraph' shape
-- stays structurally equivalent to the 8.D hand-wired
-- version — same per-template node counts, same writer-before-
-- reader ordering, same 'bfWrites' / 'bfReads' shape — only
-- the literal bus index changes from the hand-picked '7' to
-- the deterministic '16' (the default 'eoBusBase').
sendReturnEnsemble :: Auth.AuthoredEnsemble
sendReturnEnsemble = either error id $ Auth.ensemble $ do
  sendBus <- Auth.busNamed "main-send"
  Auth.voice "voice" $ runSynth $ do
    lfo       <- sinOsc 5.0 0.0
    deviation <- gain lfo 8.0           -- ±8 Hz vibrato depth
    pitch     <- add 110.0 deviation    -- 110 Hz ± 8 Hz
    carrier   <- sawOsc pitch 0.0
    amped     <- gain carrier 0.4       -- attenuate before send
    Auth.send sendBus (Auth.mono amped)
  Auth.fx "fx" $ runSynth $ do
    sent     <- Auth.returnBus sendBus
    filtered <- Auth.lpfM sent (Param 800.0) (Param 0.7)
    Auth.outMono 0 filtered             -- → hardware bus 0

sendReturnVoice :: SynthGraph
sendReturnVoice = case lookup "voice" (Auth.aeTemplates sendReturnEnsemble) of
  Just g  -> g
  Nothing -> error "sendReturnVoice: voice template missing from ensemble"

sendReturnFx :: SynthGraph
sendReturnFx = case lookup "fx" (Auth.aeTemplates sendReturnEnsemble) of
  Just g  -> g
  Nothing -> error "sendReturnFx: fx template missing from ensemble"

sendReturnDemo :: [(String, SynthGraph)]
sendReturnDemo = Auth.aeTemplates sendReturnEnsemble

{- Note [Demo body: single-graph vs multi-template]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A demo is either a single SynthGraph (the legacy single-template
shape, used by every demo before §2.D.3) or a list of named
SynthGraphs that compileTemplateGraph composes into an ensemble.

The two paths diverge in three places:

  1. Compilation: SingleGraph runs through traceCompile + lowerGraph
     + compileRuntimeGraph; MultiTemplate runs through
     compileTemplateGraph (which internally runs lowerGraph +
     compileRuntimeGraph for each entry, then derives precedence
     and topo-sorts).

  2. Inspection: SingleGraph plugs into the existing
     launchInspector / printTraceSummary path. MultiTemplate has
     no per-graph inspector yet; we print the template list and
     the bus footprint per template instead.

  3. Loading: SingleGraph uses loadRuntimeGraph; MultiTemplate uses
     loadTemplateGraph (which auto-spawns one instance per template
     so a typical single-voice-per-template ensemble works without
     explicit setup).

The shared part is realtime audio: both paths use the same
startAudio / waitAudioStarted / stopAudio bracket, since the C
runtime treats both as "iterate every live instance of every
template" once loaded.
-}

data DemoBody
  = SingleGraph SynthGraph
    -- ^ Legacy single-template demo. Compiles via traceCompile +
    -- compileRuntimeGraph, loads via loadRuntimeGraph, runs against
    -- the auto-created template 0 / instance 0 of an RTGraph.
  | MultiTemplate [(String, SynthGraph)]
    -- ^ Multi-template demo (§2.D.3). Compiles via
    -- compileTemplateGraph, loads via loadTemplateGraph. The
    -- compiler picks template execution order to match the
    -- topological sort over inter-template bus precedence.
  | MidiPoly Int (SynthM PolyMidiBindings)
    -- ^ Live-MIDI poly synth (Phase 3 closing piece). The 'Int' is
    -- polyphony; the builder returns the bindings the runner needs
    -- to wire MIDI input to per-voice controls. Compiles via
    -- 'compileTemplateGraph' as a single-template ensemble, sets
    -- polyphony, pre-warms the per-template pool, then opens a
    -- 'MetaSonic.Bridge.MidiDemo.MidiDemo' session around the
    -- realtime audio bracket.

------------------------------------------------------------
-- Named-control demo (Phase 8.G)
------------------------------------------------------------
--
-- Single-template demo that exercises 'control' + 'ccControl'.
-- The graph itself is tiny — its job is to prove the
-- authoring metadata path, not to demonstrate DSP.
--
-- Shape: saw -> lpf (cutoff via 'control') -> gain (vol via
-- 'ccControl') -> out 0. Both controls flow through tagged
-- KSmooth nodes; OSC dispatch resolves them at
-- /<voice>/<name>/1 and the CC binding lands on the same
-- smoother slot 1 — see notes/2026-05-12-k-phase-8f-named-controls.md.

namedControlBuild :: SynthM (Auth.NamedControl, Auth.NamedControl)
namedControlBuild = do
  cutoffName <- case Auth.controlName "cutoff" of
    Right n  -> pure n
    Left err -> error $ "named-control demo: " <> err
  cutoffRng <- case Auth.controlRange 200 8000 of
    Right r  -> pure r
    Left err -> error $ "named-control demo: " <> err
  cutoff <- Auth.control cutoffName 1200.0 cutoffRng

  volName <- case Auth.controlName "vol" of
    Right n  -> pure n
    Left err -> error $ "named-control demo: " <> err
  volRng <- case Auth.controlRange 0 1 of
    Right r  -> pure r
    Left err -> error $ "named-control demo: " <> err
  vol <- Auth.ccControl 7 volName 0.3 volRng

  osc    <- sawOsc 220.0 0.0
  filt   <- lpf osc (Auth.controlConnection cutoff)
                    (Param 0.7)
  master <- gain filt (Auth.controlConnection vol)
  _      <- out 0 master
  pure (cutoff, vol)

namedControlGraph :: SynthGraph
namedControlGraph =
  let (_, g) = runSynthWith namedControlBuild
  in g

namedControlAuthoring :: AuthoringReport
namedControlAuthoring =
  let ((cutoff, vol), _) = runSynthWith namedControlBuild
      base = emptyAuthoringReport
        { Report.arTemplates =
            [ Report.ReportedTemplate
                { Report.rtName = "named-control"
                , Report.rtRole = Auth.VoiceTemplate
                }
            ]
        }
  in addReportedControl vol (addReportedControl cutoff base)

------------------------------------------------------------
-- send-return ensemble metadata projection (Phase 8.G)
------------------------------------------------------------

sendReturnAuthoring :: AuthoringReport
sendReturnAuthoring = ensembleReport sendReturnEnsemble

------------------------------------------------------------

data Demo = Demo
  { demoKey       :: String
  , demoLabel     :: String
  , demoBody      :: DemoBody
  , demoAuthoring :: Maybe AuthoringReport
    -- ^ 'Just' for demos that opt in to Phase 8.G metadata
    -- reporting; 'Nothing' for legacy demos.
  }

-- | Build a demo with no authoring metadata. Use this for
-- legacy single-graph or multi-template demos that haven't
-- been migrated through Phase 8.G's reporting layer.
demoNoAuth :: String -> String -> DemoBody -> Demo
demoNoAuth key lbl body = Demo
  { demoKey       = key
  , demoLabel     = lbl
  , demoBody      = body
  , demoAuthoring = Nothing
  }

-- | Build a demo with Phase 8.G authoring metadata.
demoWithAuth
  :: String -> String -> DemoBody
  -> AuthoringReport -> Demo
demoWithAuth key lbl body r = Demo
  { demoKey       = key
  , demoLabel     = lbl
  , demoBody      = body
  , demoAuthoring = Just r
  }

demoTable :: [Demo]
demoTable =
  [ demoNoAuth "simple"    "Simple (SinOsc → Out)"
         (SingleGraph simpleGraph)
  , demoNoAuth "chain"     "Chain (SinOsc → Gain → Out)"
         (SingleGraph chainGraph)
  , demoNoAuth "fanout"    "Fan-out (SinOsc → 2×Gain → 2×Out)"
         (SingleGraph fanOutGraph)
  , demoNoAuth "saw"       "Saw oscillator (SawOsc → Gain → Out)"
         (SingleGraph sawGraph)
  , demoNoAuth "noise"     "White noise (NoiseGen → Gain → Out)"
         (SingleGraph noiseGraph)
  , demoNoAuth "noise-lpf" "Filtered noise (NoiseGen → LPF → Gain → Out)"
         (SingleGraph noiseLpfGraph)
  , demoNoAuth "saw-lpf"   "Resonant bass (SawOsc → LPF → Gain → Out)"
         (SingleGraph filteredSawGraph)
  , demoNoAuth "detune"    "Detuned saws (2×SawOsc beating → bus 0 → Out)"
         (SingleGraph detunedSawGraph)
  , demoNoAuth "stereo-saw"
         "Stereo detuned saws via MetaSonic.Authoring (Phase 8.D)"
         (SingleGraph authoringStereoSawGraph)
  , demoNoAuth "stereo-fx"
         "Stereo fx chain (hpfS → envS → delayS → gainS → stereoOut, Phase 8.C2)"
         (SingleGraph authoringStereoFxChainGraph)
  , demoNoAuth "ringmod"   "Ring modulation (SinOsc × SinOsc → Out)"
         (SingleGraph ringModGraph)
  , demoNoAuth "fm"        "Frequency modulation (LFO → SinOsc.freq → Out)"
         (SingleGraph fmGraph)
  , demoNoAuth "env-pluck" "Plucked-tone envelope (Env → Gain × SinOsc → Out)"
         (SingleGraph envPluckGraph)
  , demoNoAuth "im"        "Intermodulation showcase (PulseOsc-PWM → BPF-sweep → Out)"
         (SingleGraph intermodGraph)
  , demoWithAuth "named-control"
         "Named controls (Saw → LPF[cutoff] → Gain[vol=CC7] → Out, Phase 8.F/G)"
         (SingleGraph namedControlGraph)
         namedControlAuthoring
  , demoWithAuth "send-return"
         "Send/return (voice → BusOut 16 │ fx: BusIn 16 → LPF → Out, Phase 8.E/G)"
         (MultiTemplate sendReturnDemo)
         sendReturnAuthoring
  , demoNoAuth "midi-poly"
         "Live MIDI poly synth (8 voices; CC7 → master, pitch-bend ±2)"
         (MidiPoly 8 midiPolySynth)
  ]

--------------------------------------------------------------------------------
-- CLI options
--------------------------------------------------------------------------------
