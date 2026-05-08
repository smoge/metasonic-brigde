{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

module Main where

import           Control.DeepSeq            (force)
import           Control.Exception          (evaluate, finally)
import           Control.Monad              (forM_, replicateM)
import           Data.Char                  (toLower)
import           Data.Either                (partitionEithers)
import           Data.List                  (find, intercalate, nub, sort)
import           Data.Word                  (Word8)
import           Foreign.Ptr                (Ptr)
import           System.Environment         (getArgs, getProgName)
import           System.Exit                (die)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.MidiDemo  (CCMapping (..),
                                             PitchBendBinding (..),
                                             VoiceMapping (..), withMidiDemo)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types            (NodeIndex (..), NodeKind (..),
                                             PortIndex (..))
import           MetaSonic.Visualize.Trace  (CompileTrace (..), traceCompile)

import           MetaSonic.Visualize.TUI    (launchInspector)


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
-- scale pattern: gain to set deviation depth, add to set the centre.
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

data RunMode
  = AudioOnly
  | InspectThenRun
  | InspectOnly
  | FusionSurvey
    -- ^ Non-audio reporting mode (--fusion-survey). Compiles every
    -- demo through 'compileRuntimeGraphFused' and prints a coverage
    -- table: per-template fusion stats, a sink-terminal opportunity
    -- scan that flags shapes a future kernel could claim, and
    -- aggregate totals. Exits without opening audio or the TUI.
  deriving (Eq, Show)

data Options = Options
  { optMode    :: RunMode
  , optTargets :: [String]
  , optFused   :: Bool
    -- ^ When True, demos load through 'loadRuntimeGraphFused' /
    -- 'loadTemplateGraphFused' on a 'compileRuntimeGraphFused'-
    -- produced 'RuntimeGraph'. Default False — Step C is opt-in
    -- in normal demo use until benchmarking warrants flipping the
    -- default. The MIDI-poly demo is unaffected for now.
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optMode    = AudioOnly
  , optTargets = []
  , optFused   = False
  }

parseArgs :: [String] -> Either String Options
parseArgs = go defaultOptions
  where
    go :: Options -> [String] -> Either String Options
    go opts [] = Right opts
    go _    ("-h" : _) = Left ""
    go _    ("--help" : _) = Left ""
    go opts ("--inspect" : xs) =
      go opts { optMode = InspectThenRun } xs
    go opts ("--inspect-only" : xs) =
      go opts { optMode = InspectOnly } xs
    go opts ("--audio-only" : xs) =
      go opts { optMode = AudioOnly } xs
    go opts ("--fused" : xs) =
      go opts { optFused = True } xs
    go opts ("--fusion-survey" : xs) =
      go opts { optMode = FusionSurvey } xs
    go opts (x : xs)
      | "--" `prefixOf` x = Left ("Unknown option: " <> x)
      | otherwise         = go opts { optTargets = optTargets opts <> [x] } xs

    prefixOf :: String -> String -> Bool
    prefixOf p s = take (length p) s == p

resolveTargets :: [String] -> Either String [Demo]
resolveTargets [] = Right demoTable
resolveTargets ks = traverse lookupDemo ks
  where
    lookupDemo :: String -> Either String Demo
    lookupDemo raw =
      case find (\d -> normalize (demoKey d) == normalize raw) demoTable of
        Just d  -> Right d
        Nothing -> Left $
          "Unknown demo: " <> raw
          <> "\nKnown demos: " <> intercalate ", " (map demoKey demoTable)

    normalize :: String -> String
    normalize = map toLower

usage :: String -> String
usage prog = unlines
  [ "Usage:"
  , "  " <> prog <> " [--audio-only] [--fused] [DEMO ...]"
  , "  " <> prog <> " --inspect [--fused] [DEMO ...]"
  , "  " <> prog <> " --inspect-only [--fused] [DEMO ...]"
  , "  " <> prog <> " --fusion-survey [DEMO ...]"
  , ""
  , "If no demo names are given, all demos are run."
  , ""
  , "Flags:"
  , "  --fused          Use the §4.C fused-input loader path"
  , "                   (compileRuntimeGraphFused / loadRuntimeGraphFused),"
  , "                   which adds elision of single-edge scalar Gain / Add"
  , "                   chains. The §4.B region kernels (RSawLpfGain,"
  , "                   RSinGainOut, RSawLpfGainOut, ...) run on every"
  , "                   compile path and are not gated by this flag —"
  , "                   the [Fusion ...] line reports what fired regardless."
  , "                   Single-graph and multi-template demos only;"
  , "                   the live-MIDI poly demo always runs unfused."
  , "  --fusion-survey  Compile every demo through both runtime paths"
  , "                   (compileRuntimeGraph for §4.B kernel claims and"
  , "                   the sink-terminal opportunity scan; "
  , "                   compileRuntimeGraphFused for §4.C elide / RFused"
  , "                   counts) and print a coverage table — per-template"
  , "                   region-kernel claims, §4.C elisions, and a sink-"
  , "                   terminal opportunity scan flagging shapes a future"
  , "                   kernel could claim. No audio, no TUI, just the"
  , "                   report."
  , ""
  , "Availavle demos:"
  , "  " <> intercalate ", " (map demoKey demoTable)
  , ""
  , "Examples:"
  , "  " <> prog
  , "  " <> prog <> " simple"
  , "  " <> prog <> " --inspect chain"
  , "  " <> prog <> " --inspect-only fanout"
  , "  " <> prog <> " send-return            # multi-template demo"
  , "  " <> prog <> " --fused chain          # same audio, fused load"
  , "  " <> prog <> " --fused send-return    # multi-template fused"
  ]

--------------------------------------------------------------------------------
-- Runtime settings
--------------------------------------------------------------------------------

demoMaxFrames :: Int
demoMaxFrames = 256

-- <= 0 asks the runtime to infer channel count from configured Out buses.
demoOutputChannels :: Int
demoOutputChannels = 2

demoDeviceID :: Int
demoDeviceID = -1

audioReadyTimeoutMs :: Int
audioReadyTimeoutMs = 1000


main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  opts <-
    case parseArgs args of
      Left msg ->
        die $
          usage prog <>
          (if null msg then "" else "\nError: " <> msg <> "\n")
      Right x ->
        pure x

  demos <- either die pure (resolveTargets (optTargets opts))

  case optMode opts of
    FusionSurvey -> do
      putStrLn "Surveying demos for §4.B / §4.C fusion coverage."
      runFusionSurvey demos
    _ -> do
      putStrLn $
        case optMode opts of
          AudioOnly      -> "Running selected demos."
          InspectThenRun -> "Inspecting selected demos before audio."
          InspectOnly    -> "Inspecting selected demos without audio."
          FusionSurvey   -> "" -- handled above
      forM_ demos (runDemo opts)
      putStrLn "Done."

-- Top-level dispatch: route a Demo to its body-specific runner. See
-- Note [Demo body: single-graph vs multi-template].
runDemo :: Options -> Demo -> IO ()
runDemo opts demo = case demoBody demo of
  SingleGraph    g          -> runSingleDemo   opts demo g
  MultiTemplate  tpls       -> runTemplateDemo opts demo tpls
  MidiPoly       poly build -> runMidiPolyDemo opts demo poly build

-- Single-template demo runner. Identical to the pre-§2.D.3 path:
-- traceCompile → optional inspector → loadRuntimeGraph → audio.
--
-- When 'optFused opts' is True, the audio path takes the
-- 'compileRuntimeGraphFused' + 'loadRuntimeGraphFused' route
-- instead, which layers §4.C single-input rewrites (elided
-- scalar Gain / Add nodes, 'RFused' inputs on the consumer) on
-- top of the §4.B region-kernel selection that
-- 'compileRuntimeGraph' already runs. The inspector still walks
-- the unfused IR / region trace — those passes give the most
-- informative view of the source graph and are unaffected by
-- §4.C. A 'printFusionSummary' line is emitted on every path so
-- callers can compare what each mechanism claimed at a glance.
runSingleDemo :: Options -> Demo -> SynthGraph -> IO ()
runSingleDemo opts demo g = do
  let !trace = traceCompile g

  case optMode opts of
    InspectOnly -> do
      inspectTrace trace
      putBanner (demoLabel demo)
      _ <- printTraceSummary trace
      printFusionSummaryFor opts g
      putStrLn "\n  Audio skipped (--inspect-only)."
      putStrLn ""

    InspectThenRun -> do
      inspectTrace trace
      putBanner (demoLabel demo)
      _mRtUnfused <- printTraceSummary trace
      runSingleAudio opts g
      putStrLn ""

    AudioOnly -> do
      putBanner (demoLabel demo)
      _mRtUnfused <- printTraceSummary trace
      runSingleAudio opts g
      putStrLn ""

-- Print just the fusion summary for a single-graph demo, without
-- running audio. Used by --inspect-only so callers can compare
-- fused vs. unfused stats statically.
printFusionSummaryFor :: Options -> SynthGraph -> IO ()
printFusionSummaryFor opts g =
  let compileFn = if optFused opts
                    then compileRuntimeGraphFused
                    else compileRuntimeGraph
      label     = if optFused opts then "fused" else "unfused"
  in case lowerGraph g >>= compileFn of
       Left _   -> pure () -- the trace summary already reported errors
       Right rg -> printFusionSummary label rg

-- Pick the loader path for a single-graph demo based on
-- 'optFused'. The fused path recompiles from scratch via
-- 'compileRuntimeGraphFused'; the unfused path reuses the trace's
-- already-computed RuntimeGraph. The fusion summary fires once on
-- whichever path runs so the output stays consistent across modes.
runSingleAudio :: Options -> SynthGraph -> IO ()
runSingleAudio opts g
  | optFused opts =
      case lowerGraph g >>= compileRuntimeGraphFused of
        Left err -> putStrLn $ "  Compilation error (fused): " <> err
        Right rg -> do
          printFusionSummary "fused" rg
          runAudioFused rg
  | otherwise =
      case lowerGraph g >>= compileRuntimeGraph of
        Left err -> putStrLn $ "  Compilation error: " <> err
        Right rg -> do
          printFusionSummary "unfused" rg
          runAudio rg

{- Note [Multi-template demo runner]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
runTemplateDemo is the §2.D.3 counterpart of runSingleDemo. It:

  1. Calls compileTemplateGraph on the (name, SynthGraph) list,
     reporting an error on cycle / per-template compile failure.
  2. Prints a small summary: each template's name, its bus
     footprint (writes / live-reads / delayed-reads), and the
     compile-decreed execution order.
  3. In InspectOnly mode, stops there. The brick-based inspector
     is single-graph only today; bringing it up to multi-template
     would mean teaching it about TemplateGraph, which is a
     separate piece of work.
  4. In AudioOnly / InspectThenRun mode, calls loadTemplateGraph
     (which auto-spawns one instance per template) and starts the
     realtime audio stream.

The audio bracket reuses runAudioCommon — the same start/wait/stop
sequence as the single-template path — so multi-template demos
exit cleanly on Enter or on signal exactly like single-graph
demos.
-}

-- Multi-template demo runner. Picks the fused or unfused compile
-- and load path based on 'optFused'. The textual template summary
-- is unchanged across modes; the 'printFusionSummary' line per
-- template makes it visible whether the Step-C rewrite found
-- anything to fuse.
runTemplateDemo :: Options -> Demo -> [(String, SynthGraph)] -> IO ()
runTemplateDemo opts demo tpls = do
  putBanner (demoLabel demo)

  let compileFn = if optFused opts
                    then compileTemplateGraphFused
                    else compileTemplateGraph
      label     = if optFused opts then "fused" else "unfused"

  case compileFn tpls of
    Left err -> do
      putStrLn $ "  Compilation error (" <> label <> "): " <> err
      putStrLn ""

    Right tg -> do
      printTemplateGraph tg
      forM_ (tgTemplates tg) $ \tpl ->
        printFusionSummary
          (label <> " " <> show (tplName tpl))
          (tplGraph tpl)

      case optMode opts of
        InspectOnly -> do
          putStrLn "\n  Audio skipped (--inspect-only)."
          putStrLn $ "  (The brick inspector is single-graph only; "
                  <> "multi-template demos print a textual summary above.)"
          putStrLn ""

        _ -> do
          let totalNodes =
                sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
          if optFused opts
            then runTemplateAudioFused totalNodes tg
            else runTemplateAudio      totalNodes tg
          putStrLn ""

-- Live-MIDI poly synth runner. Compiles the builder as a single-
-- template graph, sets polyphony, pre-warms the per-template pool
-- (spawn-then-remove polyphony times so VoiceAllocator finds
-- Available slots on its first reserve), opens the MIDI demo
-- session, and hands off to runRealtimeBracket. The bracket waits
-- for Enter, then closes audio first and the MIDI session second
-- via withMidiDemo's bracket finalizer.
runMidiPolyDemo
  :: Options -> Demo -> Int -> SynthM PolyMidiBindings -> IO ()
runMidiPolyDemo opts demo poly build = do
  putBanner (demoLabel demo)

  case optMode opts of
    InspectOnly -> do
      putStrLn $ "  Inspector skipped — the live-MIDI demo only "
              <> "ships an audio runner."
      putStrLn ""
    _ -> do
      let (bindings, sg, ccSpecs) = runSynthCCs build
      case compileTemplateGraph [(demoKey demo, sg)] of
        Left err -> do
          putStrLn $ "  Compilation error: " <> err
          putStrLn ""
        Right tg -> case tgTemplates tg of
          [tpl] -> case resolveBindings (tplGraph tpl) bindings ccSpecs of
            Left err -> do
              putStrLn $ "  Binding resolution failed: " <> err
              putStrLn ""
            Right (vm, ccs, mpb) ->
              runMidiPolyAudio (length (rgNodes (tplGraph tpl)))
                               poly tg vm ccs mpb
          _ -> do
            putStrLn $ "  Internal error: midi-poly compiled to "
                    <> show (length (tgTemplates tg))
                    <> " templates (expected exactly 1)."
            putStrLn ""

-- Resolve the captured Connections in PolyMidiBindings to dense
-- (NodeIndex, control_index) pairs against the compiled template's
-- RuntimeGraph. A Param connection or an unknown NodeID is a
-- programming error in the demo definition; we surface it as a
-- left-side String rather than crashing.
resolveBindings
  :: RuntimeGraph
  -> PolyMidiBindings
  -> [CCSpec]
  -> Either String (VoiceMapping, [CCMapping], Maybe PitchBendBinding)
resolveBindings rg b autoCCs = do
  (fnode, fctl) <- resolvePair "freq"     (pmbFreq b)
  (gnode, gctl) <- resolvePair "gate"     (pmbGate b)
  velMaybe <- traverse (resolvePair "velocity") (pmbVelocity b)
  manualCCs <- traverse resolveCC (pmbCCs b)
  autoMappings <- traverse resolveAutoCC autoCCs
  mpb <- traverse resolvePB (pmbPitchBend b)
  pure ( VoiceMapping
           { vmFreqNode = fnode
           , vmFreqCtl  = fctl
           , vmGateNode = gnode
           , vmGateCtl  = gctl
           , vmVelocity = velMaybe
           }
       , autoMappings <> manualCCs
       , mpb
       )
  where
    resolvePair :: String -> (Connection, Int) -> Either String (NodeIndex, Int)
    resolvePair label (c, ctl) = case connectionNodeID c of
      Nothing  -> Left $ label <> " binding is a Param, not a node output"
      Just nid -> case resolveNodeIndex rg nid of
        Nothing -> Left $ label <> " node " <> show nid
                       <> " not found in compiled template"
        Just ni -> Right (ni, ctl)

    resolveCC :: (Word8, Connection, Int, Float, Float)
              -> Either String CCMapping
    resolveCC (n, c, ctl, mn, mx) = do
      (ni, _) <- resolvePair ("CC " <> show n) (c, ctl)
      pure CCMapping
        { ccNumber = n
        , ccNode   = ni
        , ccCtl    = ctl
        , ccMin    = mn
        , ccMax    = mx
        }

    -- Auto-discovered CC bindings carry NodeID directly (registered
    -- by 'cc' in the SynthM state), so resolution is one step shorter.
    resolveAutoCC :: CCSpec -> Either String CCMapping
    resolveAutoCC spec = case resolveNodeIndex rg (ccsNode spec) of
      Nothing -> Left $ "auto-CC " <> show (ccsNumber spec)
                     <> " node " <> show (ccsNode spec)
                     <> " not found in compiled template"
      Just ni -> Right CCMapping
        { ccNumber = ccsNumber spec
        , ccNode   = ni
        , ccCtl    = ccsCtl spec
        , ccMin    = realToFrac (ccsMin spec)
        , ccMax    = realToFrac (ccsMax spec)
        }

    resolvePB :: (Connection, Int, Float)
              -> Either String PitchBendBinding
    resolvePB (c, ctl, st) = do
      (ni, _) <- resolvePair "pitch-bend" (c, ctl)
      pure PitchBendBinding
        { pbNode      = ni
        , pbCtl       = ctl
        , pbSemitones = st
        }

-- Wire the loaded template graph + MIDI bindings to the audio bracket.
-- 'capacity' is a soft hint for the runtime's node-vector pre-alloc.
runMidiPolyAudio
  :: Int                       -- ^ runtime capacity hint
  -> Int                       -- ^ polyphony
  -> TemplateGraph
  -> VoiceMapping
  -> [CCMapping]
  -> Maybe PitchBendBinding
  -> IO ()
runMidiPolyAudio capacity poly tg vm ccs mpb =
  withRTGraph capacity demoMaxFrames $ \rt -> do
    loadTemplateGraph rt tg

    -- Set the per-template polyphony cap and pre-warm the pool so
    -- VoiceAllocator's first reserve finds an Available slot. This
    -- mirrors make_graph_with_polyphony in the C++ tests: remove
    -- the auto-spawned instance 0, spawn `poly` instances, then
    -- remove all of them.
    let cTid = 0
    c_rt_graph_template_set_polyphony rt cTid (fromIntegral poly)
    c_rt_graph_instance_remove rt 0
    spawned <- replicateM poly (c_rt_graph_template_instance_add rt cTid)
    mapM_ (c_rt_graph_instance_remove rt) spawned

    putStrLn $ "  Polyphony=" <> show poly
            <> ", template_id=" <> show cTid
            <> "; opening MIDI session..."

    withMidiDemo rt 0 poly Nothing vm ccs mpb 0xFFFF $ \mh ->
      case mh of
        Nothing -> do
          putStrLn $ "  Failed to open MIDI session "
                  <> "(allocation or thread spawn failed)."
        Just _  -> do
          putStrLn $ "  MIDI session live. If a controller is "
                  <> "plugged in, play notes / send CCs / pitch-bend."
          putStrLn $ "  No-MIDI environments still run cleanly — "
                  <> "the worker stays idle and audio remains silent."
          runRealtimeBracket rt

inspectTrace :: CompileTrace -> IO ()
inspectTrace = launchInspector

putBanner :: String -> IO ()
putBanner label = do
  putStrLn "\n══════════════════════════════════════"
  putStrLn $ "  " <> label
  putStrLn   "══════════════════════════════════════"

-- Print a TemplateGraph as a compact textual summary: per-template
-- bus footprint plus the precedence DAG that drove the topo sort.
-- Parallels printTraceSummary for the single-graph path; deliberately
-- terse since multi-template demos are typically small (2-3 templates).
printTemplateGraph :: TemplateGraph -> IO ()
printTemplateGraph tg = do
  putStrLn "\n  Templates (execution order):"
  forM_ (zip [(0 :: Int) ..] (tgTemplates tg)) $ \(i, t) -> do
    let fp = tplFootprint t
    putStrLn $
      "    " <> show i <> ". " <> tplName t
      <> "  writes=" <> show (bfWrites fp)
      <> "  live-reads=" <> show (bfReads fp)
      <> "  delayed-reads=" <> show (bfDelayedReads fp)

printTraceSummary :: CompileTrace -> IO (Maybe RuntimeGraph)
printTraceSummary ct =
  case ctIR ct of
    Nothing -> do
      putStrLn $
        "  Compilation error: " <>
        maybe "unknown failure" id (ctError ct)
      pure Nothing

    Just ir0 -> do
      ir <- evaluate (force ir0)
      putStrLn "\n  IR nodes (execution order):"
      mapM_ printIRNode (giNodes ir)

      case ctRegions ct of
        Nothing ->
          pure ()
        Just regions0 -> do
          regions <- evaluate (force regions0)
          putStrLn "\n  Regions:"
          mapM_ printRegion (rgRegions regions)

      case ctRuntime ct of
        Nothing -> do
          putStrLn $
            "\n  Compilation error: " <>
            maybe "runtime lowering failed" id (ctError ct)
          pure Nothing

        Just rt0 -> do
          rt <- evaluate (force rt0)
          putStrLn "\n  Runtime nodes (dense):"
          mapM_ printRTNode (rgNodes rt)
          pure (Just rt)

-- Single-template realtime audio: wraps loadRuntimeGraph in the
-- standard start/wait/stop bracket.
runAudio :: RuntimeGraph -> IO ()
runAudio rg =
  withRTGraph (length (rgNodes rg)) demoMaxFrames $ \rt -> do
    loadRuntimeGraph rt rg
    runRealtimeBracket rt

-- Step C: same shape as runAudio but loads the fused 'RuntimeGraph'
-- through 'loadRuntimeGraphFused'. The bracket is identical — only
-- the loader changes.
runAudioFused :: RuntimeGraph -> IO ()
runAudioFused rg =
  withRTGraph (length (rgNodes rg)) demoMaxFrames $ \rt -> do
    loadRuntimeGraphFused rt rg
    runRealtimeBracket rt

-- Multi-template realtime audio: wraps loadTemplateGraph in the
-- same start/wait/stop bracket. The 'capacity' argument to
-- withRTGraph is a soft hint for vector pre-allocation; we sum
-- node counts across all templates so it's not under-provisioned.
runTemplateAudio :: Int -> TemplateGraph -> IO ()
runTemplateAudio capacity tg =
  withRTGraph capacity demoMaxFrames $ \rt -> do
    loadTemplateGraph rt tg
    runRealtimeBracket rt

-- Step C: fused multi-template realtime audio. Same bracket as
-- runTemplateAudio; the only difference is the loader.
runTemplateAudioFused :: Int -> TemplateGraph -> IO ()
runTemplateAudioFused capacity tg =
  withRTGraph capacity demoMaxFrames $ \rt -> do
    loadTemplateGraphFused rt tg
    runRealtimeBracket rt

-- Print a fusion summary for a compiled 'RuntimeGraph'. The
-- one-line header reports counts that distinguish §4.C
-- single-input fusion ('elided' / 'fused-inputs') from §4.B
-- region-kernel selection ('region-kernels'), so an at-a-glance
-- read shows which mechanism actually fired. §4.C runs only on
-- the 'compileRuntimeGraphFused' path; §4.B runs unconditionally
-- inside 'compileRuntimeGraph' (via 'selectRegionKernels'), so a
-- non-zero region-kernels count can show up on a graph that was
-- never asked for "fused" at the command line — that's intended.
--
-- When at least one region was claimed by a fused kernel, the
-- summary continues with one indented line per claimed region,
-- listing its 'rrIndex', kernel tag, [first..last] dense node
-- range, and member kind sequence. Useful for spotting whether a
-- demo actually exercises the new kernels at all.
printFusionSummary :: String -> RuntimeGraph -> IO ()
printFusionSummary label rg = do
  let nodes        = length (rgNodes rg)
      elidedN      = length (filter rnElided (rgNodes rg))
      fusedN       = length [() | n <- rgNodes rg, RFused _ <- rnInputs n]
      fusedRegions = [r | r <- rgRuntimeRegions rg, rrKernel r /= RNodeLoop]
      buses        = sort $ nub
        [ truncate v :: Int
        | n <- rgNodes rg
        , rnKind n == KOut || rnKind n == KBusOut
        , v : _ <- [rnControls n]
        , v >= 0
        ]
      kindOf = (`lookup` [(rnIndex n, rnKind n) | n <- rgNodes rg])
  putStrLn $ "  [Fusion " <> label <> "] nodes=" <> show nodes
          <> " elided=" <> show elidedN
          <> " fused-inputs=" <> show fusedN
          <> " region-kernels=" <> show (length fusedRegions)
          <> " buses=" <> show buses
  mapM_ (printRegionLine kindOf) fusedRegions

-- One indented detail line per claimed §4.B region.
printRegionLine
  :: (NodeIndex -> Maybe NodeKind) -> RuntimeRegion -> IO ()
printRegionLine kindOf r = do
  let RegionIndex ri = rrIndex r
      members        = rrNodes r
      kinds          = [show k | ix <- members, Just k <- [kindOf ix]]
      rangeShown     = case members of
        []       -> "[]"
        [NodeIndex i] -> "[" <> show i <> "]"
        (NodeIndex i : _) ->
          let NodeIndex j = last members
          in "[" <> show i <> ".." <> show j <> "]"
  putStrLn $ "    region " <> show ri
          <> ": " <> show (rrKernel r)
          <> " " <> rangeShown
          <> " kinds=[" <> intercalate "," kinds <> "]"

--------------------------------------------------------------------------------
-- §4.B / §4.C fusion-coverage survey (--fusion-survey)
--------------------------------------------------------------------------------

-- Canonical sink-terminal shape the survey scans for in dense
-- 'RuntimeNode' order. The opportunity scan reports one row per
-- (shape, found, claimed) triple so we can read off both what the
-- current kernel set catches and what a future kernel would have
-- caught — i.e. shapes whose §4.B preconditions hold but whose
-- chain wasn't claimed by any region kernel today.
data SinkShape
  = SinkOscGain    !NodeKind   -- producer → Gain → sink
  | SinkOscLpfGain !NodeKind   -- producer → LPF → Gain → sink
  deriving (Eq, Show)

-- The full enumeration of shapes the survey reports on. Listed in
-- a deliberate display order: 3-node sinks first (the strongest
-- fusion class per notes/fusion-strategy.md), then 4-node sinks;
-- producer kinds within each group follow 'sinkProducerKinds'.
-- Iterating this list (rather than keying a Map by SinkShape)
-- avoids needing 'Ord NodeKind' and gives stable column order.
allKnownShapes :: [SinkShape]
allKnownShapes =
  [SinkOscGain    k | k <- sinkProducerKinds]
  <> [SinkOscLpfGain k | k <- sinkProducerKinds]

-- Producer kinds the survey treats as "oscillator-like" sources.
-- Restricted to the kinds that already exist in the DSL and that
-- a §4.B kernel could plausibly absorb; multi-input nodes (Add,
-- Gain) and stateful processors (Env, LPF, Smooth) are outside
-- this set.
sinkProducerKinds :: [NodeKind]
sinkProducerKinds = [KSinOsc, KSawOsc, KTriOsc, KPulseOsc, KNoiseGen]

renderProducer :: NodeKind -> String
renderProducer KSinOsc   = "Sin"
renderProducer KSawOsc   = "Saw"
renderProducer KTriOsc   = "Tri"
renderProducer KPulseOsc = "Pulse"
renderProducer KNoiseGen = "Noise"
renderProducer k         = show k

renderShape :: SinkShape -> String
renderShape (SinkOscGain k)    = renderProducer k <> " → Gain → sink"
renderShape (SinkOscLpfGain k) = renderProducer k <> " → LPF → Gain → sink"

-- Whether the §4.B kernel set currently has a kernel that would
-- claim this shape (independent of whether the kernel
-- preconditions hold on any specific instance).
shapeHasKernel :: SinkShape -> Bool
shapeHasKernel (SinkOscGain    KSinOsc) = True   -- RSinGainOut
shapeHasKernel (SinkOscGain    KSawOsc) = True   -- RSawGainOut
shapeHasKernel (SinkOscLpfGain KSawOsc) = True   -- RSawLpfGainOut
shapeHasKernel _                        = False

-- Sink-terminal classifier: matches NodeKind.{Out,BusOut} on the
-- C++ side / 'isSinkTerminal' on the Haskell matcher side.
isSinkKind :: NodeKind -> Bool
isSinkKind k = k == KOut || k == KBusOut

-- Mirror the §4.B 'signalSourceIs' / 'isScalarGain' precondition
-- helpers — kept inline rather than imported because the matcher
-- helpers in 'MetaSonic.Bridge.Compile' aren't exported (they
-- shouldn't leak into the public API).
signalSourceIsRT :: NodeIndex -> RuntimeNode -> Bool
signalSourceIsRT srcIx node = case rnInputs node of
  RFrom s (PortIndex 0) : _ -> s == srcIx
  _                         -> False

isScalarGainRT :: RuntimeNode -> Bool
isScalarGainRT node = case rnInputs node of
  [RFrom _ _, RConst _] -> True
  _                     -> False

windows3 :: [a] -> [(a, a, a)]
windows3 (a : b : c : rest) = (a, b, c) : windows3 (b : c : rest)
windows3 _                  = []

windows4 :: [a] -> [(a, a, a, a)]
windows4 (a : b : c : d : rest) = (a, b, c, d) : windows4 (b : c : d : rest)
windows4 _                      = []

-- Walk a 'RuntimeGraph' in dense order, collecting each contiguous
-- sub-sequence whose §4.B preconditions hold. Each result carries
-- whether the chain ended up in a single non-RNodeLoop region —
-- i.e. whether some kernel actually claimed it.
scanSinkShapes :: RuntimeGraph -> [(SinkShape, Bool)]
scanSinkShapes rt =
     concatMap check3 (windows3 (rgNodes rt))
  ++ concatMap check4 (windows4 (rgNodes rt))
  where
    fusedRegions = [r | r <- rgRuntimeRegions rt, rrKernel r /= RNodeLoop]
    inSameFusedRegion ixs =
      any (\r -> all (`elem` rrNodes r) ixs) fusedRegions

    check3 (a, b, c)
      | rnKind a `elem` sinkProducerKinds
      , rnKind b == KGain
      , isSinkKind (rnKind c)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , isScalarGainRT b
      , not (rnElided a) && not (rnElided b) && not (rnElided c)
      = [( SinkOscGain (rnKind a)
         , inSameFusedRegion [rnIndex a, rnIndex b, rnIndex c] )]
      | otherwise = []

    check4 (a, b, c, d)
      | rnKind a `elem` sinkProducerKinds
      , rnKind b == KLPF
      , rnKind c == KGain
      , isSinkKind (rnKind d)
      , rnConsumerCount a == 1
      , rnConsumerCount b == 1
      , rnConsumerCount c == 1
      , signalSourceIsRT (rnIndex a) b
      , signalSourceIsRT (rnIndex b) c
      , signalSourceIsRT (rnIndex c) d
      , isScalarGainRT c
      , not (rnElided a) && not (rnElided b)
                         && not (rnElided c) && not (rnElided d)
      = [( SinkOscLpfGain (rnKind a)
         , inSameFusedRegion
             [rnIndex a, rnIndex b, rnIndex c, rnIndex d] )]
      | otherwise = []

-- Per-template summary row.
data SurveyRow = SurveyRow
  { srDemo         :: !String
  , srTemplate     :: !(Maybe String)
  , srNodes        :: !Int
  , srRegions      :: !Int
  , srFusedRegions :: !Int
  , srClaimedNodes :: !Int
  , srKernels      :: ![(RegionKernel, Int)]
  , srElided       :: !Int
  , srRFused       :: !Int
  , srShapes       :: ![(SinkShape, Bool)]
  } deriving (Eq, Show)

-- Build a SurveyRow from /two/ compiled 'RuntimeGraph's of the
-- same source 'SynthGraph':
--
--   * 'rt'    — produced by 'compileRuntimeGraph'. This already
--               contains §4.B's region kernel selection (because
--               'selectRegionKernels' runs unconditionally inside
--               compileRuntimeGraph), but no §4.C elision. The
--               §4.B counts and the sink-shape scan run against
--               this graph.
--   * 'rtF'   — produced by 'compileRuntimeGraphFused' (the same
--               'rt' with §4.C single-input rewrites layered on
--               top). The §4.C 'elided' and 'RFused' counts come
--               from this graph.
--
-- Running the shape scan against 'rt' rather than 'rtF' is
-- load-bearing: §4.C elides scalar gains in chains §4.B didn't
-- claim (the same chains the survey is trying to flag as
-- "missed kernel opportunities"), and elided gains fail the
-- shape predicate. Scanning 'rtF' would silently zero out
-- exactly the rows the survey exists to surface.
surveyRuntimeGraph
  :: String -> Maybe String -> RuntimeGraph -> RuntimeGraph -> SurveyRow
surveyRuntimeGraph d t rt rtF =
  let allRegions  = rgRuntimeRegions rt
      fused       = [r | r <- allRegions, rrKernel r /= RNodeLoop]
      -- Enumerate kernel kinds via Bounded/Enum rather than keying
      -- a Map by RegionKernel (which has no Ord instance), and
      -- drop empty rows. Stable display order = constructor order.
      kernelTally = [ (k, n)
                    | k <- [minBound .. maxBound :: RegionKernel]
                    , k /= RNodeLoop
                    , let n = length (filter ((== k) . rrKernel) fused)
                    , n > 0
                    ]
  in SurveyRow
       { srDemo         = d
       , srTemplate     = t
       , srNodes        = length (rgNodes rt)
       , srRegions      = length allRegions
       , srFusedRegions = length fused
       , srClaimedNodes = sum (map (length . rrNodes) fused)
       , srKernels      = kernelTally
       , srElided       = length (filter rnElided (rgNodes rtF))
       , srRFused       = length [() | n <- rgNodes rtF, RFused _ <- rnInputs n]
       , srShapes       = scanSinkShapes rt
       }

-- | Compile a 'SynthGraph' for the survey. Returns 'Left' with a
-- caller-friendly @"demo=…[ template=…]: <err>"@ message on
-- compile failure so the survey driver can surface it instead of
-- silently dropping the row. Coverage totals are misleading if a
-- targeted graph just disappears.
surveySynthGraph
  :: String -> Maybe String -> SynthGraph -> Either String SurveyRow
surveySynthGraph d t g = do
  let stamp err = surveyTag d t <> ": " <> err
  rt  <- either (Left . stamp) Right (lowerGraph g >>= compileRuntimeGraph)
  rtF <- either (Left . stamp) Right (lowerGraph g >>= compileRuntimeGraphFused)
  Right (surveyRuntimeGraph d t rt rtF)

-- | A short human label used in error messages.
surveyTag :: String -> Maybe String -> String
surveyTag d Nothing  = "demo=" <> d
surveyTag d (Just t) = "demo=" <> d <> " template=" <> t

-- | Compile every (demo, template) pair, returning one
-- 'Either String SurveyRow' per pair so the driver can split
-- successes from failures.
surveyDemo :: Demo -> [Either String SurveyRow]
surveyDemo demo = case demoBody demo of
  SingleGraph g ->
    [surveySynthGraph (demoKey demo) Nothing g]
  MultiTemplate tpls ->
    [ surveySynthGraph (demoKey demo) (Just name) g | (name, g) <- tpls ]
  MidiPoly _ build ->
    let (_b, g, _cc) = runSynthCCs build
    in [surveySynthGraph (demoKey demo) Nothing g]

-- Top-level entry for the --fusion-survey mode. Produces the
-- per-template summary, a sink-terminal opportunity table, and
-- aggregate totals. Compile failures are surfaced explicitly:
-- they're not counted in the totals (because we have no graph to
-- count) but they /are/ reported in a dedicated banner so a
-- failed-but-targeted graph doesn't silently lower aggregate
-- coverage. Exits with status 1 if any survey row failed, since
-- the resulting numbers are by definition incomplete.
runFusionSurvey :: [Demo] -> IO ()
runFusionSurvey demos = do
  let results        = concatMap surveyDemo demos
      (errs, rows)   = partitionEithers results
  putStrLn ""
  printSurveyTable rows
  putStrLn ""
  printOpportunityScan rows
  putStrLn ""
  printSurveyTotals rows
  putStrLn ""
  case errs of
    [] -> putStrLn "Done."
    es -> do
      putStrLn "─── Survey failures ───"
      mapM_ (\e -> putStrLn ("  " <> e)) es
      putStrLn ""
      die $ "Done with " <> show (length es)
          <> " compile failure(s); coverage totals above exclude them."

-- Per-template table.
printSurveyTable :: [SurveyRow] -> IO ()
printSurveyTable rows = do
  putStrLn "─── Per-template fusion summary ───"
  putStrLn $ formatSurveyRow
    [ "demo", "template", "nodes", "regs"
    , "§4.B-regs", "§4.B-cov", "§4.C-elide", "§4.C-RFused", "kernels"
    ]
  mapM_ (putStrLn . formatSurveyRow . renderSurveyRow) rows

renderSurveyRow :: SurveyRow -> [String]
renderSurveyRow r =
  [ srDemo r
  , maybe "" id (srTemplate r)
  , show (srNodes r)
  , show (srRegions r)
  , show (srFusedRegions r)
  , covPct (srClaimedNodes r) (srNodes r)
  , show (srElided r)
  , show (srRFused r)
  , kernelTallyText (srKernels r)
  ]

covPct :: Int -> Int -> String
covPct _ 0 = "—"
covPct c n = show ((c * 100) `div` n) <> "%"

kernelTallyText :: [(RegionKernel, Int)] -> String
kernelTallyText [] = "—"
kernelTallyText xs =
  intercalate ", " [show k <> "×" <> show n | (k, n) <- xs]

formatSurveyRow :: [String] -> String
formatSurveyRow cols =
  intercalate "  " (zipWith pad surveyColumnWidths cols)
  where
    pad w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

surveyColumnWidths :: [Int]
surveyColumnWidths = [14, 14, 5, 5, 9, 8, 10, 11, 30]

-- Opportunity scan: for each known sink-terminal shape, how many
-- candidate chains the survey saw, how many were claimed by a
-- §4.B kernel, and how many were missed. Shapes with no kernel
-- today appear with a "kernel? —" marker; those rows are the
-- raw signal for "is it worth adding a Tri / Pulse / etc.
-- kernel".
printOpportunityScan :: [SurveyRow] -> IO ()
printOpportunityScan rows = do
  putStrLn "─── Sink-terminal opportunity scan ───"
  putStrLn $ formatScanRow ["shape", "found", "claimed", "missed", "kernel?"]
  mapM_ (putStrLn . formatScanRow) (scanRows rows)
  where
    formatScanRow cols =
      intercalate "  " (zipWith padCell scanColumnWidths cols)
    padCell w s
      | length s >= w = s
      | otherwise     = s <> replicate (w - length s) ' '

scanColumnWidths :: [Int]
scanColumnWidths = [32, 6, 8, 7, 8]

scanRows :: [SurveyRow] -> [[String]]
scanRows rows =
  let allShapes = concatMap srShapes rows
      countFor sh =
        let matching = [c | (s, c) <- allShapes, s == sh]
            claimed  = length (filter id matching)
            found    = length matching
        in (found, claimed, found - claimed)
  in [ [ renderShape sh
       , show found
       , show claimed
       , show missed
       , if shapeHasKernel sh then "yes" else "—"
       ]
     | sh <- allKnownShapes
     , let (found, claimed, missed) = countFor sh
     , found > 0 || shapeHasKernel sh
     ]

-- Aggregate totals across every surveyed template.
printSurveyTotals :: [SurveyRow] -> IO ()
printSurveyTotals rows = do
  let totalNodes     = sum (map srNodes rows)
      totalClaimed   = sum (map srClaimedNodes rows)
      totalRegions   = sum (map srRegions rows)
      totalFused     = sum (map srFusedRegions rows)
      totalElided    = sum (map srElided rows)
      totalRFused    = sum (map srRFused rows)
      totalShapes    = sum (map (length . srShapes) rows)
      shapesClaimed  =
        sum [length (filter snd (srShapes r)) | r <- rows]
      shapesMissed   = totalShapes - shapesClaimed
  putStrLn "─── Totals ───"
  putStrLn $ "  Templates surveyed:        " <> show (length rows)
  putStrLn $ "  Runtime nodes:             " <> show totalNodes
  putStrLn $ "  Regions (all):             " <> show totalRegions
  putStrLn $ "  §4.B fused regions:        " <> show totalFused
  putStrLn $ "  Nodes in fused regions:    "
          <> show totalClaimed <> " / " <> show totalNodes
          <> " (" <> covPct totalClaimed totalNodes <> ")"
  putStrLn $ "  §4.C elided nodes:         " <> show totalElided
  putStrLn $ "  §4.C RFused inputs:        " <> show totalRFused
  putStrLn ""
  putStrLn $ "  Sink-terminal candidate chains:    " <> show totalShapes
  putStrLn $ "    claimed by a §4.B kernel:        " <> show shapesClaimed
  putStrLn $ "    missed (no kernel for the shape, or"
  putStrLn $ "             precondition didn't hold): " <> show shapesMissed

-- Shared realtime audio entry point: start, wait for the callback
-- to fire, accept Enter to stop, and unwind via 'finally' so the
-- stream is always cleaned up even on early exit. Used by both the
-- single-template and multi-template runners.
runRealtimeBracket :: Ptr RTGraph -> IO ()
runRealtimeBracket rt = do
  putStrLn "\n  Starting realtime audio..."
  startRC <- startAudio rt demoOutputChannels demoDeviceID
  if startRC /= 0
    then
      putStrLn $ "  Audio start failed with status " <> show startRC
    else
      flip finally (stopAudio rt) $ do
        ready <- waitAudioStarted rt audioReadyTimeoutMs
        if ready
          then do
            putStrLn "  Press Enter to stop audio."
            _ <- getLine
            pure ()
          else
            putStrLn $
              "  Audio stream opened, but the callback did not report "
              <> "ready within " <> show audioReadyTimeoutMs <> " ms."


printIRNode :: NodeIR -> IO ()
printIRNode n =
  putStrLn $ "    " <> show (irNodeID n)
          <> " : " <> show (irKind n)
          <> " @ " <> show (irRate n)
          <> "  effects=" <> show (irEffects n)

printRegion :: Region -> IO ()
printRegion r =
  putStrLn $ "    " <> show (regID r)
          <> " [" <> show (regRate r) <> "]"
          <> "  nodes=" <> show (regNodes r)
          <> "  deps=" <> show (regDeps r)

printRTNode :: RuntimeNode -> IO ()
printRTNode n =
  putStrLn $ "    " <> show (rnIndex n)
          <> " ← " <> show (rnOriginalID n)
          <> " : " <> show (rnKind n)
