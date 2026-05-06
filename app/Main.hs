{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

module Main where

import           Control.DeepSeq           (force)
import           Control.Exception         (evaluate, finally)
import           Control.Monad             (forM_)
import           Data.Char                 (toLower)
import           Data.List                 (find, intercalate)
import           System.Environment        (getArgs, getProgName)
import           System.Exit               (die)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Visualize.Trace (CompileTrace (..), traceCompile)

import           MetaSonic.Visualize.TUI   (launchInspector)


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
  osc2 <- sawOsc 220.5 0.5   --  phase offset avoids phase cancellation
  g1   <- gain osc1 0.3
  g2   <- gain osc2 0.3
  out 0 g1
  out 0 g2                   -- second out accumulates onto same bus

-- Ring modulation: 440 Hz carrier multiplied sample-by-sample by a 7 Hz
-- modulator. Both signals are bipolar, so this is genuine ring mod
-- (sum/difference frequencies) rather than amplitude modulation.
-- Final 0.3 gain stage keeps the output at a reasonable level.
ringModGraph :: SynthGraph
ringModGraph = runSynth $ do
  carrier   <- sinOsc 440.0 0.0
  modulator <- sinOsc 7.0 0.0
  ring      <- gain' (audio carrier) (audio modulator)
  amped     <- gain ring 0.3
  out 0 amped

-- Vibrato: a 5 Hz LFO biased by 440 Hz drives the carrier's
-- frequency between 410 and 470 Hz. Demonstrates the full bias-and-
-- scale pattern: gain to set deviation depth, add to set the centre.
fmGraph :: SynthGraph
fmGraph = runSynth $ do
  lfo       <- sinOsc 5.0 0.0
  deviation <- gain lfo 30.0      -- ±30 Hz
  freq      <- add 440.0 deviation
  carrier   <- sinOsc' (audio freq) (Param 0.0)
  amped     <- gain carrier 0.3
  out 0 amped

demoTable :: [Demo]
demoTable =
  [ Demo "simple"    "Simple (SinOsc → Out)"                           simpleGraph
  , Demo "chain"     "Chain (SinOsc → Gain → Out)"                     chainGraph
  , Demo "fanout"    "Fan-out (SinOsc → 2×Gain → 2×Out)"               fanOutGraph
  , Demo "saw"       "Saw oscillator (SawOsc → Gain → Out)"            sawGraph
  , Demo "noise"     "White noise (NoiseGen → Gain → Out)"             noiseGraph
  , Demo "noise-lpf" "Filtered noise (NoiseGen → LPF → Gain → Out)"   noiseLpfGraph
  , Demo "saw-lpf"   "Resonant bass (SawOsc → LPF → Gain → Out)"      filteredSawGraph
  , Demo "detune"    "Detuned saws (2×SawOsc beating → bus 0 → Out)"  detunedSawGraph
  , Demo "ringmod"   "Ring modulation (SinOsc × SinOsc → Out)"        ringModGraph
  , Demo "fm"        "Frequency modulation (LFO → SinOsc.freq → Out)" fmGraph
  ]

data Demo = Demo
  { demoKey   :: String
  , demoLabel :: String
  , demoGraph :: SynthGraph
  }

--------------------------------------------------------------------------------
-- CLI options
--------------------------------------------------------------------------------

data RunMode
  = AudioOnly
  | InspectThenRun
  | InspectOnly
  deriving (Eq, Show)

data Options = Options
  { optMode    :: RunMode
  , optTargets :: [String]
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optMode    = AudioOnly
  , optTargets = []
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
  , "  " <> prog <> " [--audio-only] [DEMO ...]"
  , "  " <> prog <> " --inspect [DEMO ...]"
  , "  " <> prog <> " --inspect-only [DEMO ...]"
  , ""
  , "If no demo names are given, all demos are run."
  , ""
  , "Availavle demos:"
  , "  " <> intercalate ", " (map demoKey demoTable)
  , ""
  , "Examples:"
  , "  " <> prog
  , "  " <> prog <> " simple"
  , "  " <> prog <> " --inspect chain"
  , "  " <> prog <> " --inspect-only fanout"
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

  putStrLn $
    case optMode opts of
      AudioOnly      -> "Running selected demos."
      InspectThenRun -> "Inspecting selected demos before audio."
      InspectOnly    -> "Inspecting selected demos without audio."

  forM_ demos (runDemo opts)

  putStrLn "Done."

runDemo :: Options -> Demo -> IO ()
runDemo opts demo = do
  let !trace = traceCompile (demoGraph demo)

  case optMode opts of
    InspectOnly -> do
      inspectTrace trace
      putBanner (demoLabel demo)
      _ <- printTraceSummary trace
      putStrLn "\n  Audio skipped (--inspect-only)."
      putStrLn ""

    InspectThenRun -> do
      inspectTrace trace
      putBanner (demoLabel demo)
      mRt <- printTraceSummary trace
      maybe (pure ()) runAudio mRt
      putStrLn ""

    AudioOnly -> do
      putBanner (demoLabel demo)
      mRt <- printTraceSummary trace
      maybe (pure ()) runAudio mRt
      putStrLn ""

inspectTrace :: CompileTrace -> IO ()
inspectTrace = launchInspector

putBanner :: String -> IO ()
putBanner label = do
  putStrLn "\n══════════════════════════════════════"
  putStrLn $ "  " <> label
  putStrLn   "══════════════════════════════════════"

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

runAudio :: RuntimeGraph -> IO ()
runAudio rg =
  withRTGraph (length (rgNodes rg)) demoMaxFrames $ \rt -> do
    loadRuntimeGraph rt rg

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
