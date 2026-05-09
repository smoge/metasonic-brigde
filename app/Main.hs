{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

module Main where

import           Control.DeepSeq            (force)
import           Control.Exception          (evaluate, finally)
import           Control.Monad              (forM_, replicateM)
import           Data.Char                  (toLower)
import           Data.List                  (find, intercalate)
import           Data.Word                  (Word8)
import           Foreign.Ptr                (Ptr)
import           System.Environment         (getArgs, getProgName)
import           System.Exit                (die)

import           MetaSonic.App.Demos
import           MetaSonic.App.Survey       (printFusionSummary,
                                             runFusionSurvey)
import           MetaSonic.App.WorkerBench  (runWorkerBench)
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.MidiDemo  (CCMapping (..),
                                             PitchBendBinding (..),
                                             VoiceMapping (..), withMidiDemo)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.Types            (NodeIndex (..))
import           MetaSonic.Visualize.Trace  (CompileTrace (..), traceCompile)

import           MetaSonic.Visualize.TUI    (launchInspector)


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
  | WorkerBench
    -- ^ Non-audio reporting mode (--worker-bench). Compiles demos
    -- plus the fixed corpus, loads them through the Haskell FFI path,
    -- and times legacy vs schedule-worker modes.
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
    go opts ("--worker-bench" : xs) =
      go opts { optMode = WorkerBench } xs
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
  , "  " <> prog <> " --worker-bench [DEMO ...]"
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
  , "                   kernel could claim. The fixed 'surveyShapeProbes'"
  , "                   single-graph set plus 'surveyEnsembleCorpus'"
  , "                   multi-template ensembles (corpus:* rows) are always"
  , "                   included regardless of demo targeting; demos and"
  , "                   corpus get separate subtotals. No audio, no TUI,"
  , "                   just the report."
  , "  --worker-bench   Compile demos plus the fixed survey corpus, load"
  , "                   them through the Haskell FFI path, and time the"
  , "                   legacy direct executor against schedule-serial,"
  , "                   pool direct, and pool reduction modes. No audio,"
  , "                   no TUI."
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

  let runDemos banner = do
        putStrLn banner
        forM_ demos (runDemo opts)
        putStrLn "Done."

  case optMode opts of
    FusionSurvey -> do
      putStrLn "Surveying demos for §4.B / §4.C fusion coverage."
      runFusionSurvey demos
    WorkerBench -> do
      putStrLn "Benchmarking Haskell-loaded schedule worker modes."
      runWorkerBench demos
    AudioOnly      -> runDemos "Running selected demos."
    InspectThenRun -> runDemos "Inspecting selected demos before audio."
    InspectOnly    -> runDemos "Inspecting selected demos without audio."

-- Top-level dispatch: route a Demo to its body-specific runner. See
-- Note [Demo body: single-graph vs multi-template].
runDemo :: Options -> Demo -> IO ()
runDemo opts demo
  -- 'main' routes reporting modes before 'runDemo' is reached.
  -- Guard the dispatch boundary explicitly so a future re-routing
  -- mistake fails loudly here, rather than silently running audio.
  -- The single guard covers all three body-specific runners.
  | optMode opts == FusionSurvey || optMode opts == WorkerBench =
      error "runDemo: reporting modes should be handled by main, never reach here"
  | otherwise = case demoBody demo of
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

    -- 'main' routes 'FusionSurvey' to 'runFusionSurvey' before
    -- 'runDemo' is reached, so this branch is unreachable. Make
    -- that intent explicit so the case is exhaustive (rather than
    -- leaning on a wildcard that would also swallow real bugs).
    FusionSurvey ->
      error "runSingleDemo: FusionSurvey should be handled by main, never reach here"
    WorkerBench ->
      error "runSingleDemo: WorkerBench should be handled by main, never reach here"

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
