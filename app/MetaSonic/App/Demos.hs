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
  , demoTemplateGraph
  , demoManifestReloadCatalogEntry
  , demoManifestReloadCatalog
    -- * Phase 8.G: authoring metadata reporting
  , namedControlGraph
  , namedControlAuthoring
  , sendReturnAuthoring
  , preserveCutoffDarkAuthoring
  , preserveCutoffBrightAuthoring
  , dronePreserveSawDark
  , dronePreserveSawBright
  , rejectPreservingDelayDarkAuthoring
  , rejectPreservingDelayBrightAuthoring
  , dronePreserveDelayDark
  , dronePreserveDelayBright
  , preserveSmoothCutoffDarkAuthoring
  , preserveSmoothCutoffBrightAuthoring
  , dronePreserveSmoothCutoffDark
  , dronePreserveSmoothCutoffBright
  ) where

import           Data.Maybe                (catMaybes)
import           Data.Word                 (Word8)

import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Manifest
                                            (manifestFromReport)
import           MetaSonic.Authoring.Report (AuthoringReport,
                                             addReportedControl,
                                             emptyAuthoringReport,
                                             ensembleReport)
import qualified MetaSonic.Authoring.Report as Report
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates (TemplateGraph,
                                             compileTemplateGraph)
import           MetaSonic.Session.ManifestReload
                                            (ManifestReloadCatalogEntry (..))

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
  vol <- Auth.ccControl 10 volName 0.3 volRng

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
-- Preserving hot-swap demo pair
------------------------------------------------------------
--
-- Two audible app-side drone graphs that swap under the
-- @try-preserving@ strategy and emit @MrhsrPreserving@. Both
-- compile to a single "drone" template with the same migration
-- keys ("carrier" on the sawOsc, "lpf" on the LPF). Only the LPF
-- cutoff baseline differs: 'dronePreserveSawDark' opens at 600 Hz,
-- 'dronePreserveSawBright' at 2400 Hz. A saw carrier (rather than
-- the sine carrier used by 'MetaSonic.Pattern.Corpus.hotSwapEdit')
-- has enough harmonic content above 600 Hz that the LPF cutoff
-- change is audibly unmistakable.
--
-- The matching authoring reports declare one control each, bound
-- DIRECTLY to the LPF's @cutoff@ input (migration key "lpf",
-- slot 0 — see KLPF in Types.hs) and addressable through *two*
-- ingress paths: OSC on @/v<voice>/lpf/0@ and MIDI on CC 74
-- (GM2 "Brightness / Sound Controller 5", the standard filter-
-- cutoff CC). The binding intentionally does NOT route through
-- 'Auth.control' / KSmooth, because KSmooth is
-- 'PreserveUnsupported' in 'preservingHotSwapNodeClass'
-- (RTGraphAdapter.hs) and would make the preserving reload reject.
-- The trade-off is that OSC / MIDI writes arrive unsmoothed —
-- acceptable for a manual preserving demo. Smooth authored
-- controls across preserving reload are a separate slice unless
-- KSmooth becomes preservable.

dronePreserveSawDark :: SynthGraph
dronePreserveSawDark = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 600.0) (Param 0.7))
  shaped   <- gain filtered (Param 0.2)
  out 0 shaped

dronePreserveSawBright :: SynthGraph
dronePreserveSawBright = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 2400.0) (Param 0.7))
  shaped   <- gain filtered (Param 0.2)
  out 0 shaped

-- | Control declaration for the dark preserving entry: display
-- name "cutoff", direct binding to KLPF slot 0 via migration key
-- "lpf", default matching the graph baseline, addressable via
-- OSC at @/v<voice>/lpf/0@ and MIDI CC 74 (GM2 filter cutoff).
-- Unsmoothed (see header note).
preserveCutoffControlDark :: Report.ReportedControl
preserveCutoffControlDark = Report.ReportedControl
  { Report.rcName        = "cutoff"
  , Report.rcDefault     = 600.0
  , Report.rcRange       = (200.0, 6000.0)
  , Report.rcSmoothingHz = 0.0
  , Report.rcCC          = Just 74
  , Report.rcKey         = MigrationKey "lpf"
  , Report.rcSlot        = 0
  }

-- | OSC control declaration for the bright preserving entry.
-- Same binding shape as 'preserveCutoffControlDark' but the default
-- matches the bright graph baseline.
preserveCutoffControlBright :: Report.ReportedControl
preserveCutoffControlBright = preserveCutoffControlDark
  { Report.rcDefault = 2400.0 }

preserveCutoffDarkAuthoring :: AuthoringReport
preserveCutoffDarkAuthoring = emptyAuthoringReport
  { Report.arTemplates =
      [ Report.ReportedTemplate
          { Report.rtName = "drone"
          , Report.rtRole = Auth.VoiceTemplate
          }
      ]
  , Report.arControls = [preserveCutoffControlDark]
  }

preserveCutoffBrightAuthoring :: AuthoringReport
preserveCutoffBrightAuthoring = emptyAuthoringReport
  { Report.arTemplates =
      [ Report.ReportedTemplate
          { Report.rtName = "drone"
          , Report.rtRole = Auth.VoiceTemplate
          }
      ]
  , Report.arControls = [preserveCutoffControlBright]
  }

------------------------------------------------------------
-- Smooth preserving hot-swap baseline pair
------------------------------------------------------------
--
-- Phase 8d-a fixture pair. Unlike 'preserve-cutoff', this pair
-- routes the cutoff through 'Auth.ccControl', which emits a tagged
-- 'KSmooth' named "cutoff". Under the 8d-a preserving contract,
-- KSmooth participates in preserving validation but default-inits
-- its runtime state after the swap; the artifact harness measures
-- the resulting post-install block deviation before the later
-- KSmooth prewarm/copy slice tightens it.

smoothCutoffBuild :: Double -> SynthM Auth.NamedControl
smoothCutoffBuild cutoffDefault = do
  cutoffName <- case Auth.controlName "cutoff" of
    Right n  -> pure n
    Left err -> error $ "preserve-smooth-cutoff demo: " <> err
  cutoffRng <- case Auth.controlRange 200 6000 of
    Right r  -> pure r
    Left err -> error $ "preserve-smooth-cutoff demo: " <> err
  cutoff <- Auth.ccControl 74 cutoffName cutoffDefault cutoffRng

  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"
                (lpf carrier (Auth.controlConnection cutoff) (Param 0.7))
  shaped   <- tagged "gain" (gain filtered (Param 0.2))
  _        <- out 0 shaped
  pure cutoff

dronePreserveSmoothCutoffDark :: SynthGraph
dronePreserveSmoothCutoffDark =
  let (_, g) = runSynthWith (smoothCutoffBuild 600.0)
  in g

dronePreserveSmoothCutoffBright :: SynthGraph
dronePreserveSmoothCutoffBright =
  let (_, g) = runSynthWith (smoothCutoffBuild 2400.0)
  in g

preserveSmoothCutoffAuthoring :: Double -> AuthoringReport
preserveSmoothCutoffAuthoring cutoffDefault =
  let (cutoff, _) = runSynthWith (smoothCutoffBuild cutoffDefault)
      base = emptyAuthoringReport
        { Report.arTemplates =
            [ Report.ReportedTemplate
                { Report.rtName = "drone"
                , Report.rtRole = Auth.VoiceTemplate
                }
            ]
        }
  in addReportedControl cutoff base

preserveSmoothCutoffDarkAuthoring :: AuthoringReport
preserveSmoothCutoffDarkAuthoring =
  preserveSmoothCutoffAuthoring 600.0

preserveSmoothCutoffBrightAuthoring :: AuthoringReport
preserveSmoothCutoffBrightAuthoring =
  preserveSmoothCutoffAuthoring 2400.0

------------------------------------------------------------
-- Reject-eligible preserving hot-swap pair
------------------------------------------------------------
--
-- Sibling of the 'preserve-cutoff' pair above, deliberately
-- shaped to make the preserving hot-swap REJECT instead of
-- commit. Used to exercise the
-- 'SupervisedReloadRequestRejected' branch of the live session
-- shell deterministically (without racing an OSC reload-window
-- or relying on a bad demo key).
--
-- Mechanism: the voice template carries a 'delayL' (KDelay)
-- node on the wet path. KDelay is classified as
-- 'PreserveUnsupported' by 'preservingHotSwapNodeClass'
-- (RTGraphAdapter.hs), so any active voice using a template
-- with KDelay fails the runtime preserving-migration check
-- with 'SriHotSwapWouldPreserveVoices'. The downstream
-- classification chain is
--   StepRuntimeFailed
--     -> mapPreservingReloadReport: HprfOldOwnerStillInstalled
--     -> orchestrator: HpariReloadRejected (resume-old-ingress
--                      succeeds; old stack stays live)
--     -> classifyPreservingOutcome: InWindowReloadRejectedLiveFallback
--     -> reloadSupervised: SupervisedReloadRequestRejected.
--
-- The user-facing control contract is intentionally identical
-- to 'preserve-cutoff': one OSC/MIDI-addressable cutoff control
-- on KLPF slot 0 via migration key "lpf". The KDelay node is
-- a topology decoration that affects voice migrability only;
-- it is NOT in the control path.

dronePreserveDelayDark :: SynthGraph
dronePreserveDelayDark = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 600.0) (Param 0.7))
  wet      <- tagged "delay"   (delayL 1.0 filtered (Param 0.3))
  shaped   <- gain wet (Param 0.2)
  out 0 shaped

dronePreserveDelayBright :: SynthGraph
dronePreserveDelayBright = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 2400.0) (Param 0.7))
  wet      <- tagged "delay"   (delayL 1.0 filtered (Param 0.3))
  shaped   <- gain wet (Param 0.2)
  out 0 shaped

-- | Cutoff control for the dark reject-eligible entry. Binding
-- shape (migration key "lpf", slot 0, OSC @/v<voice>/lpf/0@,
-- MIDI CC 74, default 600 Hz) is identical to
-- 'preserveCutoffControlDark'; only the demo containing it
-- differs.
rejectPreservingDelayControlDark :: Report.ReportedControl
rejectPreservingDelayControlDark = preserveCutoffControlDark

-- | Cutoff control for the bright reject-eligible entry; default
-- 2400 Hz, otherwise identical to the dark variant.
rejectPreservingDelayControlBright :: Report.ReportedControl
rejectPreservingDelayControlBright = preserveCutoffControlBright

rejectPreservingDelayDarkAuthoring :: AuthoringReport
rejectPreservingDelayDarkAuthoring = emptyAuthoringReport
  { Report.arTemplates =
      [ Report.ReportedTemplate
          { Report.rtName = "drone"
          , Report.rtRole = Auth.VoiceTemplate
          }
      ]
  , Report.arControls = [rejectPreservingDelayControlDark]
  }

rejectPreservingDelayBrightAuthoring :: AuthoringReport
rejectPreservingDelayBrightAuthoring = emptyAuthoringReport
  { Report.arTemplates =
      [ Report.ReportedTemplate
          { Report.rtName = "drone"
          , Report.rtRole = Auth.VoiceTemplate
          }
      ]
  , Report.arControls = [rejectPreservingDelayControlBright]
  }

------------------------------------------------------------
-- Phase 8b — Tier 1 repertoire (saw + noise families)
------------------------------------------------------------
--
-- Four single-template drone demos in two preserving-compatible
-- pairs. The saw family ('saw-filter-dark' / 'saw-filter-bright')
-- lands on the 'RSawLpfGainOut' kernel; the noise family
-- ('noise-filter-soft' / 'noise-filter-sharp') lands on
-- 'RNoiseLpfGainOut'.
--
-- Every voice exposes its controls as direct 'ReportedControl'
-- bindings on tagged primitive nodes — never through
-- 'Auth.control' / 'ccControl', which would emit a 'KSmooth' and
-- break preserving compatibility. See
-- notes/2026-05-22-a-live-session-repertoire-design.md for the
-- design rationale and slot-mapping verification:
--   * KLPF      slot 0 = cutoff  slot 1 = q
--   * KGain     slot 0 = amount
--   * KSawOsc   slot 0 = freq    (phase is initial-only — avoid)
--
-- All four voices tag their stateful source as "carrier" so a
-- cross-family preserving reload (saw <-> noise) hits the
-- kind-mismatch arm of 'validateStatefulNode' on the same
-- migration key — a reject path the existing fixture set does
-- not exercise.

droneSawFilterDark :: SynthGraph
droneSawFilterDark = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 600.0) (Param 0.7))
  shaped   <- tagged "gain"    (gain filtered (Param 0.2))
  out 0 shaped

droneSawFilterBright :: SynthGraph
droneSawFilterBright = runSynth $ do
  carrier  <- tagged "carrier" (sawOsc (Param 220.0) (Param 0.0))
  filtered <- tagged "lpf"     (lpf carrier (Param 2400.0) (Param 0.7))
  shaped   <- tagged "gain"    (gain filtered (Param 0.2))
  out 0 shaped

droneNoiseFilterSoft :: SynthGraph
droneNoiseFilterSoft = runSynth $ do
  source   <- tagged "carrier" noiseGen
  filtered <- tagged "lpf"     (lpf source (Param 900.0) (Param 1.0))
  shaped   <- tagged "gain"    (gain filtered (Param 0.15))
  out 0 shaped

droneNoiseFilterSharp :: SynthGraph
droneNoiseFilterSharp = runSynth $ do
  source   <- tagged "carrier" noiseGen
  filtered <- tagged "lpf"     (lpf source (Param 3200.0) (Param 3.0))
  shaped   <- tagged "gain"    (gain filtered (Param 0.15))
  out 0 shaped

-- | Pitch control on the saw family's KSawOsc carrier. No
-- canonical CC: oscillator frequency is normally driven by note
-- number, not a controller.
pitchControl :: Double -> Report.ReportedControl
pitchControl def = Report.ReportedControl
  { Report.rcName        = "pitch"
  , Report.rcDefault     = def
  , Report.rcRange       = (55.0, 880.0)
  , Report.rcSmoothingHz = 0.0
  , Report.rcCC          = Nothing
  , Report.rcKey         = MigrationKey "carrier"
  , Report.rcSlot        = 0
  }

-- | Cutoff control on the tagged KLPF. CC 74 = GM2 "Sound
-- Controller 5 / Brightness", the conventional filter-cutoff CC
-- (matches preserve-cutoff).
cutoffControl :: Double -> Report.ReportedControl
cutoffControl def = Report.ReportedControl
  { Report.rcName        = "cutoff"
  , Report.rcDefault     = def
  , Report.rcRange       = (200.0, 6000.0)
  , Report.rcSmoothingHz = 0.0
  , Report.rcCC          = Just 74
  , Report.rcKey         = MigrationKey "lpf"
  , Report.rcSlot        = 0
  }

-- | Resonance control on the tagged KLPF. CC 71 = GM2 "Sound
-- Controller 2 / Timbre / Harmonic Content", the conventional
-- filter-resonance CC.
qControl :: Double -> Report.ReportedControl
qControl def = Report.ReportedControl
  { Report.rcName        = "q"
  , Report.rcDefault     = def
  , Report.rcRange       = (0.3, 4.0)
  , Report.rcSmoothingHz = 0.0
  , Report.rcCC          = Just 71
  , Report.rcKey         = MigrationKey "lpf"
  , Report.rcSlot        = 1
  }

-- | Output level on the tagged KGain. CC 7 = channel volume.
-- Range tops out below unity so the dark/bright contrast stays
-- comfortable; widen if a session wants louder output.
levelControl :: Double -> Report.ReportedControl
levelControl def = Report.ReportedControl
  { Report.rcName        = "level"
  , Report.rcDefault     = def
  , Report.rcRange       = (0.0, 0.5)
  , Report.rcSmoothingHz = 0.0
  , Report.rcCC          = Just 7
  , Report.rcKey         = MigrationKey "gain"
  , Report.rcSlot        = 0
  }

droneVoiceTemplate :: Report.ReportedTemplate
droneVoiceTemplate = Report.ReportedTemplate
  { Report.rtName = "drone"
  , Report.rtRole = Auth.VoiceTemplate
  }

sawFilterDarkAuthoring :: AuthoringReport
sawFilterDarkAuthoring = emptyAuthoringReport
  { Report.arTemplates = [droneVoiceTemplate]
  , Report.arControls  =
      [ pitchControl  220.0
      , cutoffControl 600.0
      , qControl      0.7
      , levelControl  0.2
      ]
  }

sawFilterBrightAuthoring :: AuthoringReport
sawFilterBrightAuthoring = emptyAuthoringReport
  { Report.arTemplates = [droneVoiceTemplate]
  , Report.arControls  =
      [ pitchControl  220.0
      , cutoffControl 2400.0
      , qControl      0.7
      , levelControl  0.2
      ]
  }

noiseFilterSoftAuthoring :: AuthoringReport
noiseFilterSoftAuthoring = emptyAuthoringReport
  { Report.arTemplates = [droneVoiceTemplate]
  , Report.arControls  =
      [ cutoffControl 900.0
      , qControl      1.0
      , levelControl  0.15
      ]
  }

noiseFilterSharpAuthoring :: AuthoringReport
noiseFilterSharpAuthoring = emptyAuthoringReport
  { Report.arTemplates = [droneVoiceTemplate]
  , Report.arControls  =
      [ cutoffControl 3200.0
      , qControl      3.0
      , levelControl  0.15
      ]
  }

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
         "Named controls (Saw → LPF[cutoff] → Gain[vol=CC10] → Out, Phase 8.F/G)"
         (SingleGraph namedControlGraph)
         namedControlAuthoring
  , demoWithAuth "send-return"
         "Send/return (voice → BusOut 16 │ fx: BusIn 16 → LPF → Out, Phase 8.E/G)"
         (MultiTemplate sendReturnDemo)
         sendReturnAuthoring
  , demoWithAuth "preserve-cutoff-dark"
         "Preserving hot-swap source (saw drone @ LPF 600 Hz; OSC cutoff /v0/lpf/0)"
         (MultiTemplate [("drone", dronePreserveSawDark)])
         preserveCutoffDarkAuthoring
  , demoWithAuth "preserve-cutoff-bright"
         "Preserving hot-swap target (saw drone @ LPF 2400 Hz; OSC cutoff /v0/lpf/0)"
         (MultiTemplate [("drone", dronePreserveSawBright)])
         preserveCutoffBrightAuthoring
  , demoWithAuth "preserve-smooth-cutoff-dark"
         "Preserving KSmooth baseline source (saw drone @ smoothed LPF 600 Hz)"
         (MultiTemplate [("drone", dronePreserveSmoothCutoffDark)])
         preserveSmoothCutoffDarkAuthoring
  , demoWithAuth "preserve-smooth-cutoff-bright"
         "Preserving KSmooth baseline target (saw drone @ smoothed LPF 2400 Hz)"
         (MultiTemplate [("drone", dronePreserveSmoothCutoffBright)])
         preserveSmoothCutoffBrightAuthoring
  , demoWithAuth "reject-preserving-delay-dark"
         "Reject-eligible preserving source (saw drone @ LPF 600 Hz, +KDelay wet path)"
         (MultiTemplate [("drone", dronePreserveDelayDark)])
         rejectPreservingDelayDarkAuthoring
  , demoWithAuth "reject-preserving-delay-bright"
         "Reject-eligible preserving target (saw drone @ LPF 2400 Hz, +KDelay wet path)"
         (MultiTemplate [("drone", dronePreserveDelayBright)])
         rejectPreservingDelayBrightAuthoring
  , demoWithAuth "saw-filter-dark"
         "Phase 8b saw drone (LPF 600 Hz, q 0.7, level 0.2; pitch/cutoff/q/level controls)"
         (MultiTemplate [("drone", droneSawFilterDark)])
         sawFilterDarkAuthoring
  , demoWithAuth "saw-filter-bright"
         "Phase 8b saw drone (LPF 2400 Hz, q 0.7, level 0.2; pitch/cutoff/q/level controls)"
         (MultiTemplate [("drone", droneSawFilterBright)])
         sawFilterBrightAuthoring
  , demoWithAuth "noise-filter-soft"
         "Phase 8b noise drone (LPF 900 Hz, q 1.0, level 0.15; cutoff/q/level controls)"
         (MultiTemplate [("drone", droneNoiseFilterSoft)])
         noiseFilterSoftAuthoring
  , demoWithAuth "noise-filter-sharp"
         "Phase 8b noise drone (LPF 3200 Hz, q 3.0, level 0.15; cutoff/q/level controls)"
         (MultiTemplate [("drone", droneNoiseFilterSharp)])
         noiseFilterSharpAuthoring
  , demoNoAuth "midi-poly"
         "Live MIDI poly synth (8 voices; CC7 → master, pitch-bend ±2)"
         (MidiPoly 8 midiPolySynth)
  ]

-- | Compile a demo body into the template graph shape that session-owner
-- construction and manifest reload planning consume.
--
-- Single-graph and MIDI demos use the demo key as the template name, matching
-- the app runtime paths. Multi-template demos keep their authored template
-- names.
demoTemplateGraph :: Demo -> Either String TemplateGraph
demoTemplateGraph demo =
  compileTemplateGraph (demoTemplateRows demo)

-- | Build a manifest reload catalog entry for an authored demo.
--
-- Demos without authoring metadata are not reload-catalog entries yet. The
-- manifest is derived from the same report that export uses; the graph is
-- compiled from the app-owned demo body.
demoManifestReloadCatalogEntry
  :: Demo
  -> Either String (Maybe ManifestReloadCatalogEntry)
demoManifestReloadCatalogEntry demo =
  case demoAuthoring demo of
    Nothing ->
      Right Nothing
    Just report -> do
      graph <- demoTemplateGraph demo
      pure $ Just ManifestReloadCatalogEntry
        { mrcDemoKey       = demoKey demo
        , mrcManifest      = manifestFromReport (demoKey demo) report
        , mrcTemplateGraph = graph
        }

-- | App-owned manifest reload catalog for every authored demo in a table.
--
-- This is intentionally not CLI wiring and does not read external JSON. It is
-- the adapter from the app's demo registry to the pure session planner's
-- catalog input.
demoManifestReloadCatalog
  :: [Demo]
  -> Either String [ManifestReloadCatalogEntry]
demoManifestReloadCatalog demos =
  catMaybes <$> traverse demoManifestReloadCatalogEntry demos

demoTemplateRows :: Demo -> [(String, SynthGraph)]
demoTemplateRows demo =
  case demoBody demo of
    SingleGraph graph ->
      [(demoKey demo, graph)]
    MultiTemplate templates ->
      templates
    MidiPoly _ build ->
      let (_, graph) = runSynthWith build
      in [(demoKey demo, graph)]

--------------------------------------------------------------------------------
-- CLI options
--------------------------------------------------------------------------------
