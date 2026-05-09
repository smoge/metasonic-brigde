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
  ) where

import           Data.Word                 (Word8)

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

sendReturnVoice :: SynthGraph
sendReturnVoice = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 8.0           -- ±8 Hz vibrato depth
  pitch     <- add 110.0 deviation    -- 110 Hz ± 8 Hz
  carrier   <- sawOsc pitch 0.0
  amped     <- gain carrier 0.4       -- attenuate before send
  busOut 7 amped                      -- → shared send bus 7

sendReturnFx :: SynthGraph
sendReturnFx = runSynth $ do
  send     <- busIn 7                 -- read voice's send
  filtered <- lpf send 800.0 0.7      -- LPF at 800 Hz
  out 0 filtered                      -- → hardware bus 0

sendReturnDemo :: [(String, SynthGraph)]
sendReturnDemo =
  [ ("voice", sendReturnVoice)
  , ("fx",    sendReturnFx)
  ]

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

data Demo = Demo
  { demoKey   :: String
  , demoLabel :: String
  , demoBody  :: DemoBody
  }

demoTable :: [Demo]
demoTable =
  [ Demo "simple"    "Simple (SinOsc → Out)"
         (SingleGraph simpleGraph)
  , Demo "chain"     "Chain (SinOsc → Gain → Out)"
         (SingleGraph chainGraph)
  , Demo "fanout"    "Fan-out (SinOsc → 2×Gain → 2×Out)"
         (SingleGraph fanOutGraph)
  , Demo "saw"       "Saw oscillator (SawOsc → Gain → Out)"
         (SingleGraph sawGraph)
  , Demo "noise"     "White noise (NoiseGen → Gain → Out)"
         (SingleGraph noiseGraph)
  , Demo "noise-lpf" "Filtered noise (NoiseGen → LPF → Gain → Out)"
         (SingleGraph noiseLpfGraph)
  , Demo "saw-lpf"   "Resonant bass (SawOsc → LPF → Gain → Out)"
         (SingleGraph filteredSawGraph)
  , Demo "detune"    "Detuned saws (2×SawOsc beating → bus 0 → Out)"
         (SingleGraph detunedSawGraph)
  , Demo "ringmod"   "Ring modulation (SinOsc × SinOsc → Out)"
         (SingleGraph ringModGraph)
  , Demo "fm"        "Frequency modulation (LFO → SinOsc.freq → Out)"
         (SingleGraph fmGraph)
  , Demo "env-pluck" "Plucked-tone envelope (Env → Gain × SinOsc → Out)"
         (SingleGraph envPluckGraph)
  , Demo "im"        "Intermodulation showcase (PulseOsc-PWM → BPF-sweep → Out)"
         (SingleGraph intermodGraph)
  , Demo "send-return"
         "Send/return (voice → BusOut 7 │ fx: BusIn 7 → LPF → Out)"
         (MultiTemplate sendReturnDemo)
  , Demo "midi-poly"
         "Live MIDI poly synth (8 voices; CC7 → master, pitch-bend ±2)"
         (MidiPoly 8 midiPolySynth)
  ]

--------------------------------------------------------------------------------
-- CLI options
--------------------------------------------------------------------------------
