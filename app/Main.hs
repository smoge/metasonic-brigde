{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

module Main where

import           Control.DeepSeq            (force)
import           Control.Exception          (evaluate, finally)
import           Control.Monad              (forM_, replicateM)
import           Data.Bifunctor             (first)
import           Data.Char                  (isDigit, toLower)
import           Data.List                  (find, intercalate)
import qualified Data.Map.Strict            as M
import           Data.Word                  (Word8)
import           Foreign.Ptr                (Ptr)
import           System.Environment         (getArgs, getProgName)
import           System.Exit                (die)

import           MetaSonic.App.CorpusSurvey (runCorpusSurvey)
import qualified Data.ByteString.Lazy.Char8  as BL
import           MetaSonic.Authoring.Manifest (AuthoringManifestDoc (..),
                                                 encodeManifestDoc,
                                                 manifestFromReport,
                                                 manifestSchemaVersion)
import           MetaSonic.Authoring.Report (renderAuthoringReport)
import           MetaSonic.App.Demos
import           MetaSonic.App.FusionCostLab (FusionCostLabOptions (..),
                                              OutputFormat (..),
                                              runFusionCostLab)
import qualified MetaSonic.App.FusionCostLab as FCL
import           MetaSonic.App.ManifestReloadCli
                                            (manifestReloadHostStrategyNames,
                                             parseManifestReloadHostStrategy,
                                             readManifestReloadDocFile,
                                             renderManifestReloadCliIssue,
                                             renderManifestReloadHostStrategy,
                                             runManifestHostStrategyReloadSmokeFile,
                                             runManifestStoppedAudioReloadSmokeFile)
import           MetaSonic.App.ManifestLiveReloadDemo
                                            (runManifestLiveReloadDemo)
import           MetaSonic.App.ManifestMIDIReloadSmoke
                                            (runManifestMIDIReloadSmoke)
import           MetaSonic.App.ManifestReloadHost
                                            (ManifestReloadHostStrategy)
import           MetaSonic.App.Osc          (runOscListen)
import           MetaSonic.App.SessionMidiSmoke (runSessionMidiSmoke)
import           MetaSonic.App.SessionOscArbitrationSmoke
                                             (runSessionOscArbitrationSmoke)
import           MetaSonic.App.SnapshotCheck (runSnapshotCheck)
import           MetaSonic.OSC.Listen       (defaultListenerConfig,
                                             parseListenerPort)
import           MetaSonic.App.Survey       (printFusionSummary,
                                             runFusionSurvey)
import           MetaSonic.App.SwapBench    (runSwapBench)
import           MetaSonic.App.WorkerBench  (runWorkerBench)
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.MidiDemo  (CCMapping (..),
                                             PitchBendBinding (..),
                                             VoiceMapping (..),
                                             withMidiDemo)
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.MIDI.Devices     (MidiDeviceInfo (..),
                                             midiDeviceList)
import           MetaSonic.Pattern          (ControlTag (..),
                                             SwapLabel (..),
                                             TemplateName (..))
import qualified MetaSonic.Session.ManifestReload as MR
import           MetaSonic.Session.ManifestReload.Construct
                                            (constructManifestSessionFromPlan)
import           MetaSonic.Session.Command  (SessionCommand (..))
import           MetaSonic.Session.Owner    (SessionOwnerStatus,
                                             defaultSessionOwnerOptions,
                                             sessionOwnerState,
                                             sessionOwnerStatus)
import           MetaSonic.Session.RTGraphAdapter
                                            (RTGraphAdapterOptions (..))
import           MetaSonic.Session.State    (SessionState (..))
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
  | SwapBench
    -- ^ Non-audio reporting mode (--swap-bench). Phase 5.3.C1 micro-
    -- benchmark of the Haskell hot-swap helper path against a fixed
    -- corpus of rows (unchanged, tagged osc, tagged biquad, lifecycle-
    -- only, fused, template). Targets are ignored.
  | CorpusSurvey
    -- ^ Non-audio reporting mode (--corpus-survey). Phase 6.A.3
    -- layer-(b) verification: runs the pattern corpus
    -- (MetaSonic.Pattern.Corpus) through the §4 survey machinery
    -- and prints per-row kernel coverage, corpus-wide totals,
    -- claimed / missed sink shapes, and §4.D edge-rate
    -- opportunity contribution. Targets are ignored.
  | OscListen
    -- ^ Phase 6.B.4 audio + OSC mode (--osc-listen [PORT]).
    -- Loads a built-in demo graph, starts realtime audio, and
    -- runs MetaSonic.OSC.Listen.withOscListener on the
    -- configured UDP port. Send /v0/outgain/0 ,f <amount>
    -- packets to control the output gain in real time. Demo
    -- targets are ignored.
  | MidiList
    -- ^ Non-audio reporting mode (--midi-list). Enumerates the
    -- current Q / PortMIDI device table and exits. The printed ids
    -- are the values accepted by --midi-device.
  | SessionMidiSmoke
    -- ^ Manual non-audio smoke mode (--session-midi-smoke [SECONDS]).
    -- Opens the session-backed PortMIDI source, runs it through the
    -- decoded MIDI listener and fan-in service, and reports producer /
    -- drain activity. Targets are ignored.
  | SessionOscArbitrationSmoke
    -- ^ Manual non-audio smoke mode
    -- (--session-osc-arbitration-smoke [SECONDS]). Binds an OSC
    -- session listener, routes it through the service-owned arbitration
    -- path with a target-claim policy, and reports producer / listener /
    -- service rejection activity. Targets are ignored.
  | PluginList
    -- ^ Non-audio reporting mode (--plugin-list). Enumerates the
    -- build-linked static plugin registry that KStaticPlugin resolves
    -- against on the producer side.
  | FusionCostLab
    -- ^ Non-audio reporting mode (--fusion-cost-lab). Phase 7.A
    -- tooling: generates a fixed bank of parametric graph families,
    -- compiles each through stripped-node-loop / region-kernel /
    -- RFused variants, times them, checks bit-equivalence against
    -- the baseline, and prints one machine-readable row per
    -- (family, member, variant). Use --summary to switch from
    -- JSONL to a human-readable table.
  | SnapshotCheck
    -- ^ Non-audio reporting mode (--snapshot-check). Runs the
    -- Phase 7.A read-only invariants over the survey corpus and
    -- fusion cost lab, then exits non-zero on drift.
  | AuthoringManifest
    -- ^ Non-audio reporting mode (--authoring-manifest). Phase
    -- 8.H: prints a JSON manifest of the authoring surface
    -- (templates, named buses, named controls) for each demo
    -- that opts into 'demoAuthoring'. Targets filter the demo
    -- list. Demos without authoring metadata are silently
    -- skipped; the document is always valid JSON, even when
    -- the resulting demo list is empty.
  | ManifestReloadDiagnostic
    -- ^ Non-audio diagnostic mode (--manifest-reload-plan DEMO).
    -- Adapts the built-in demo registry into a manifest reload
    -- catalog, plans one selected authored demo, and prints the
    -- static plan/control/resource projection. It does not allocate
    -- an RTGraph, start audio, enqueue a command, or claim live
    -- reload semantics.
  | ManifestReloadFileDiagnostic
    -- ^ Non-audio diagnostic mode
    -- (--manifest-reload-plan-file MANIFEST.json DEMO). Reads an
    -- external authoring manifest document, validates the selected demo
    -- against the built-in authored-demo catalog, and prints the same
    -- static plan/control/resource projection. It does not allocate an
    -- RTGraph, start audio, enqueue a command, or claim live reload
    -- semantics.
  | ManifestSessionSmoke
    -- ^ Non-audio construction smoke
    -- (--manifest-session-smoke MANIFEST.json DEMO). Reads an
    -- external authoring manifest document, validates the selected demo
    -- against the built-in authored-demo catalog, constructs a fresh
    -- SessionOwner from the resulting plan, prints status, and exits.
    -- It does not start audio, step CmdHotSwap, or claim live reload
    -- semantics.
  | ManifestStoppedAudioReloadSmoke
    -- ^ Non-audio stopped-audio reload smoke
    -- (--manifest-stopped-audio-reload-smoke MANIFEST.json DEMO). Reads an
    -- external authoring manifest document, validates the selected demo
    -- against the built-in authored-demo catalog, creates an existing
    -- fan-in host, replaces its owner with the planned manifest owner,
    -- prints status, and exits. It does not start/stop audio, reset
    -- listeners, step CmdHotSwap, or claim live reload semantics.
  | ManifestHostStrategyReloadSmoke
    -- ^ Manual non-audio host strategy smoke
    -- (--manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO).
    -- Reads an external authoring manifest document, validates the
    -- selected demo against the built-in authored-demo catalog, runs
    -- the app-level manifest reload strategy selector with fake audio
    -- lifecycle hooks, prints which strategy ran or failed, and exits.
    -- It does not open PortAudio, run the normal demo path, or make
    -- any selector mode the default.
  | ManifestMIDIReloadSmoke
    -- ^ Manual device-backed MIDI smoke
    -- (--manifest-midi-reload-smoke MANIFEST.json DEMO). Reads an
    -- external authoring manifest document, validates the selected
    -- demo against the built-in authored-demo catalog, opens a real
    -- PortMIDI input through the manifest MIDI ingress projection,
    -- and reports per-event activity (accepted CC writes,
    -- manifest-layer rejects, ignored non-CC events). It does not
    -- start audio, does not run a hot-swap, and does not claim
    -- reload semantics. Exits non-zero only when no input-capable
    -- PortMIDI device opens.
  | ManifestLiveReloadDemo
    -- ^ Experimental audible manifest reload path
    -- (--manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW).
    -- Starts real audio from OLD, opens manifest-aware OSC ingress,
    -- waits for Enter, then reloads to NEW through
    -- reloadManifestHostWithStrategy. This is opt-in only; the normal
    -- demo path is unchanged.
  deriving (Eq, Show)

data Options = Options
  { optMode    :: RunMode
  , optTargets :: [String]
  , optManifestReloadFile :: Maybe FilePath
    -- ^ External authoring manifest JSON path for manifest reload
    -- diagnostic / construction-smoke modes.
  , optManifestReloadHostStrategy :: Maybe ManifestReloadHostStrategy
    -- ^ Explicit selector mode for
    -- --manifest-host-reload-smoke.
  , optFused   :: Bool
    -- ^ When True, demos load through 'loadRuntimeGraphFused' /
    -- 'loadTemplateGraphFused' on a 'compileRuntimeGraphFused'-
    -- produced 'RuntimeGraph'. Default False — Step C is opt-in
    -- in normal demo use until benchmarking warrants flipping the
    -- default. The MIDI-poly demo is unaffected for now.
  , optOscPort :: Int
    -- ^ UDP port for --osc-listen. Default 7000.
  , optMidiDevice :: Maybe Int
    -- ^ Optional PortMIDI device id for MIDI-backed commands.
  , optFCLSummary :: Bool
    -- ^ When True, --fusion-cost-lab prints a per-row table
    -- instead of JSONL. Toggled by --summary alongside
    -- --fusion-cost-lab.
  , optSessionMidiSmokeSeconds :: Int
    -- ^ Manual smoke-test duration for --session-midi-smoke.
  , optSessionOscSmokeSeconds :: Int
    -- ^ Manual smoke-test duration for --session-osc-arbitration-smoke.
  , optSessionOscPort :: Int
    -- ^ UDP port for --session-osc-arbitration-smoke. Default 7001.
  , optManifestMIDISmokeSeconds :: Int
    -- ^ Manual smoke-test duration for --manifest-midi-reload-smoke.
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optMode    = AudioOnly
  , optTargets = []
  , optManifestReloadFile = Nothing
  , optManifestReloadHostStrategy = Nothing
  , optFused   = False
  , optOscPort = 7000
  , optMidiDevice = Nothing
  , optFCLSummary = False
  , optSessionMidiSmokeSeconds = 10
  , optSessionOscSmokeSeconds = 10
  , optSessionOscPort = 7001
  , optManifestMIDISmokeSeconds = 10
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
    go opts ("--swap-bench" : xs) =
      go opts { optMode = SwapBench } xs
    go opts ("--corpus-survey" : xs) =
      go opts { optMode = CorpusSurvey } xs
    go opts ("--fusion-cost-lab" : xs) =
      go opts { optMode = FusionCostLab } xs
    go opts ("--snapshot-check" : xs) =
      go opts { optMode = SnapshotCheck } xs
    go opts ("--authoring-manifest" : xs) =
      go opts { optMode = AuthoringManifest } xs
    go opts ("--manifest-reload-plan" : xs) =
      go opts { optMode = ManifestReloadDiagnostic } xs
    go opts ("--manifest-reload-plan-file" : path : xs)
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-reload-plan-file"
      | otherwise =
          go opts { optMode = ManifestReloadFileDiagnostic
                  , optManifestReloadFile = Just path
                  } xs
    go _ ("--manifest-reload-plan-file" : []) =
      Left "Missing manifest JSON file for --manifest-reload-plan-file"
    go opts ("--manifest-session-smoke" : path : xs)
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-session-smoke"
      | otherwise =
          go opts { optMode = ManifestSessionSmoke
                  , optManifestReloadFile = Just path
                  } xs
    go _ ("--manifest-session-smoke" : []) =
      Left "Missing manifest JSON file for --manifest-session-smoke"
    go opts ("--manifest-stopped-audio-reload-smoke" : path : xs)
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-stopped-audio-reload-smoke"
      | otherwise =
          go opts { optMode = ManifestStoppedAudioReloadSmoke
                  , optManifestReloadFile = Just path
                  } xs
    go _ ("--manifest-stopped-audio-reload-smoke" : []) =
      Left "Missing manifest JSON file for --manifest-stopped-audio-reload-smoke"
    go opts ("--manifest-host-reload-smoke" : strategyText : path : xs)
      | null strategyText || "--" `prefixOf` strategyText =
          Left $
            "Missing strategy for --manifest-host-reload-smoke"
            <> "\nStrategies: "
            <> intercalate ", " manifestReloadHostStrategyNames
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-host-reload-smoke"
      | otherwise =
          case parseManifestReloadHostStrategy strategyText of
            Just strategy ->
              go opts { optMode = ManifestHostStrategyReloadSmoke
                      , optManifestReloadFile = Just path
                      , optManifestReloadHostStrategy = Just strategy
                      } xs
            Nothing ->
              Left (invalidManifestHostStrategy strategyText)
    go _ ("--manifest-host-reload-smoke" : strategyText : [])
      | null strategyText || "--" `prefixOf` strategyText =
          Left $
            "Missing strategy for --manifest-host-reload-smoke"
            <> "\nStrategies: "
            <> intercalate ", " manifestReloadHostStrategyNames
      | otherwise =
          case parseManifestReloadHostStrategy strategyText of
            Just _ ->
              Left "Missing manifest JSON file for --manifest-host-reload-smoke"
            Nothing ->
              Left (invalidManifestHostStrategy strategyText)
    go _ ("--manifest-host-reload-smoke" : []) =
      Left $
        "Missing strategy for --manifest-host-reload-smoke"
        <> "\nStrategies: "
        <> intercalate ", " manifestReloadHostStrategyNames
    go opts ("--manifest-live-reload-demo" : strategyText : path : xs)
      | null strategyText || "--" `prefixOf` strategyText =
          Left $
            "Missing strategy for --manifest-live-reload-demo"
            <> "\nStrategies: "
            <> intercalate ", " manifestReloadHostStrategyNames
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-live-reload-demo"
      | otherwise =
          case parseManifestReloadHostStrategy strategyText of
            Just strategy ->
              go opts { optMode = ManifestLiveReloadDemo
                      , optManifestReloadFile = Just path
                      , optManifestReloadHostStrategy = Just strategy
                      } xs
            Nothing ->
              Left (invalidManifestLiveReloadStrategy strategyText)
    go _ ("--manifest-live-reload-demo" : strategyText : [])
      | null strategyText || "--" `prefixOf` strategyText =
          Left $
            "Missing strategy for --manifest-live-reload-demo"
            <> "\nStrategies: "
            <> intercalate ", " manifestReloadHostStrategyNames
      | otherwise =
          case parseManifestReloadHostStrategy strategyText of
            Just _ ->
              Left "Missing manifest JSON file for --manifest-live-reload-demo"
            Nothing ->
              Left (invalidManifestLiveReloadStrategy strategyText)
    go _ ("--manifest-live-reload-demo" : []) =
      Left $
        "Missing strategy for --manifest-live-reload-demo"
        <> "\nStrategies: "
        <> intercalate ", " manifestReloadHostStrategyNames
    go opts ("--manifest-midi-reload-smoke" : path : xs)
      | null path || "--" `prefixOf` path =
          Left "Missing manifest JSON file for --manifest-midi-reload-smoke"
      | otherwise =
          go opts { optMode = ManifestMIDIReloadSmoke
                  , optManifestReloadFile = Just path
                  } xs
    go _ ("--manifest-midi-reload-smoke" : []) =
      Left "Missing manifest JSON file for --manifest-midi-reload-smoke"
    go opts ("--manifest-midi-smoke-seconds" : s : xs) =
      case parseSmokeSeconds s of
        Just n  -> go opts { optManifestMIDISmokeSeconds = n } xs
        Nothing -> Left $
          "Invalid duration for --manifest-midi-smoke-seconds: " <> s
          <> " (expected integer seconds in [1, 3600])"
    go _ ("--manifest-midi-smoke-seconds" : []) =
      Left "Missing value for --manifest-midi-smoke-seconds"
    go opts ("--summary" : xs) =
      go opts { optFCLSummary = True } xs
    go opts ("--midi-list" : xs) =
      go opts { optMode = MidiList } xs
    go opts ("--session-midi-smoke" : xs) =
      case takeSessionMidiSmokeSeconds xs of
        Left err              -> Left err
        Right (seconds, rest) ->
          go opts { optMode = SessionMidiSmoke
                  , optSessionMidiSmokeSeconds = seconds
                  } rest
    go opts ("--session-osc-arbitration-smoke" : xs) =
      case takeSessionOscSmokeSeconds xs of
        Left err              -> Left err
        Right (seconds, rest) ->
          go opts { optMode = SessionOscArbitrationSmoke
                  , optSessionOscSmokeSeconds = seconds
                  } rest
    go opts ("--plugin-list" : xs) =
      go opts { optMode = PluginList } xs
    go opts ("--midi-device" : s : xs) =
      case parseMidiDeviceIndex s of
        Just ix -> go opts { optMidiDevice = Just ix } xs
        Nothing -> Left $
          "Invalid device for --midi-device: " <> s
          <> " (expected non-negative integer)"
    go _ ("--midi-device" : []) =
      Left "Missing value for --midi-device"
    go opts ("--session-osc-port" : s : xs) =
      case parseListenerPort s of
        Just port -> go opts { optSessionOscPort = port } xs
        Nothing -> Left $
          "Invalid port for --session-osc-port: " <> s
          <> " (expected integer in [1, 65535])"
    go _ ("--session-osc-port" : []) =
      Left "Missing value for --session-osc-port"
    go opts ("--osc-listen" : xs) = case takeOscPort xs of
      Left err           -> Left err
      Right (port, rest) ->
        go opts { optMode = OscListen, optOscPort = port } rest
    go opts (x : xs)
      | "--" `prefixOf` x = Left ("Unknown option: " <> x)
      | otherwise         = go opts { optTargets = optTargets opts <> [x] } xs

    prefixOf :: String -> String -> Bool
    prefixOf p s = take (length p) s == p

    parseMidiDeviceIndex :: String -> Maybe Int
    parseMidiDeviceIndex s
      | not (null s)
      , all isDigit s
      , length s <= 9 = Just (read s)
      | otherwise     = Nothing

    invalidManifestHostStrategy strategyText =
      "Invalid strategy for --manifest-host-reload-smoke: "
      <> strategyText
      <> " (expected one of: "
      <> intercalate ", " manifestReloadHostStrategyNames
      <> ")"

    invalidManifestLiveReloadStrategy strategyText =
      "Invalid strategy for --manifest-live-reload-demo: "
      <> strategyText
      <> " (expected one of: "
      <> intercalate ", " manifestReloadHostStrategyNames
      <> ")"

    parseSmokeSeconds :: String -> Maybe Int
    parseSmokeSeconds s
      | not (null s)
      , all isDigit s
      , length s <= 4
      , let n = read s
      , n >= 1
      , n <= 3600 = Just n
      | otherwise = Nothing

    -- Consume an optional positional integer port after
    -- --osc-listen. The next token, if present and not a flag,
    -- MUST be a valid port — silently falling back to the
    -- default would mask typos like "--osc-listen foo" or
    -- out-of-range numbers like "--osc-listen 70000".
    takeOscPort :: [String] -> Either String (Int, [String])
    takeOscPort [] = Right (optOscPort defaultOptions, [])
    takeOscPort (s : rest)
      | "--" `prefixOf` s = Right (optOscPort defaultOptions, s : rest)
      | otherwise = case parseListenerPort s of
          Just n  -> Right (n, rest)
          Nothing -> Left $
            "Invalid port for --osc-listen: " <> s
            <> " (expected integer in [1, 65535])"

    -- Consume an optional positive integer duration after
    -- --session-midi-smoke. The next token, if present and not a flag,
    -- must be a valid smoke window so typos fail loudly.
    takeSessionMidiSmokeSeconds :: [String] -> Either String (Int, [String])
    takeSessionMidiSmokeSeconds [] =
      Right (optSessionMidiSmokeSeconds defaultOptions, [])
    takeSessionMidiSmokeSeconds (s : rest)
      | "--" `prefixOf` s =
          Right (optSessionMidiSmokeSeconds defaultOptions, s : rest)
      | otherwise =
          case parseSmokeSeconds s of
            Just n  -> Right (n, rest)
            Nothing -> Left $
              "Invalid duration for --session-midi-smoke: " <> s
              <> " (expected integer seconds in [1, 3600])"

    takeSessionOscSmokeSeconds :: [String] -> Either String (Int, [String])
    takeSessionOscSmokeSeconds [] =
      Right (optSessionOscSmokeSeconds defaultOptions, [])
    takeSessionOscSmokeSeconds (s : rest)
      | "--" `prefixOf` s =
          Right (optSessionOscSmokeSeconds defaultOptions, s : rest)
      | otherwise =
          case parseSmokeSeconds s of
            Just n  -> Right (n, rest)
            Nothing -> Left $
              "Invalid duration for --session-osc-arbitration-smoke: " <> s
              <> " (expected integer seconds in [1, 3600])"

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
  , "  " <> prog <> " --swap-bench"
  , "  " <> prog <> " --corpus-survey"
  , "  " <> prog <> " --fusion-cost-lab [--summary]"
  , "  " <> prog <> " --snapshot-check"
  , "  " <> prog <> " --authoring-manifest [DEMO ...]"
  , "  " <> prog <> " --manifest-reload-plan DEMO"
  , "  " <> prog <> " --manifest-reload-plan-file MANIFEST.json DEMO"
  , "  " <> prog <> " --manifest-session-smoke MANIFEST.json DEMO"
  , "  " <> prog <> " --manifest-stopped-audio-reload-smoke MANIFEST.json DEMO"
  , "  " <> prog <> " --manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO"
  , "  " <> prog <> " --manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW"
  , "  " <> prog <> " --manifest-midi-reload-smoke MANIFEST.json DEMO"
  , "  " <> prog <> " --midi-list"
  , "  " <> prog <> " --session-midi-smoke [SECONDS]"
  , "  " <> prog <> " --session-osc-arbitration-smoke [SECONDS]"
  , "  " <> prog <> " --plugin-list"
  , "  " <> prog <> " --osc-listen [PORT]"
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
  , "  --swap-bench     Phase 5.3.C1 micro-benchmark of the Haskell"
  , "                   hot-swap helper path. Walks a fixed corpus"
  , "                   (unchanged, tagged-osc, tagged-biquad,"
  , "                   lifecycle-only, fused, template) and prints one"
  , "                   CSV row per case with publish/install timing"
  , "                   and migration counters. No audio, no TUI; demo"
  , "                   targets are ignored."
  , "  --corpus-survey  Phase 6.A.3 layer-(b) verification: runs the"
  , "                   pattern corpus rows (drone-with-vibrato,"
  , "                   arpeggio-send-return, polyphonic-stab,"
  , "                   hot-swap-edit, layered-ensemble,"
  , "                   spectral-freeze-pad) through the"
  , "                   §4 survey machinery and prints per-row kernel"
  , "                   coverage, corpus-wide kernel totals, claimed /"
  , "                   missed sink shapes, and §4.D edge-rate"
  , "                   opportunity contribution. No audio, no TUI;"
  , "                   demo targets are ignored."
  , "  --fusion-cost-lab"
  , "                   Phase 7.A fusion cost lab. Generates a fixed bank"
  , "                   of parametric and corpus graph families"
  , "                   (sink-chain, return-tail, fanout, corpus),"
  , "                   compiles each member through stripped-node-loop /"
  , "                   region-kernel / RFused variants, times them, and"
  , "                   checks bit-equivalence against the baseline. Output"
  , "                   is JSONL (one row per variant) by default; pair"
  , "                   with --summary for a human-readable table. No audio,"
  , "                   no TUI; demo targets are ignored."
  , "  --snapshot-check"
  , "                   Phase 7.A survey/cost-lab invariant checker. Runs"
  , "                   the cost-lab row/equivalence/feature checks and"
  , "                   the survey corpus compile/latency/shape checks."
  , "                   No audio, no TUI; demo targets are ignored."
  , "  --authoring-manifest"
  , "                   Phase 8.H authoring-surface manifest export."
  , "                   Prints a single JSON document describing every"
  , "                   demo that opts into authoring metadata: templates,"
  , "                   roles, named buses, named controls, ranges, CC"
  , "                   bindings, and migration keys. Demos without"
  , "                   authoring metadata are silently skipped; targets"
  , "                   filter the demo list. No audio, no TUI."
  , "  --manifest-reload-plan DEMO"
  , "                   Diagnostic-only manifest reload planning path."
  , "                   Builds the app-owned reload catalog from built-in"
  , "                   authored demos, derives the matching manifest doc,"
  , "                   plans the selected DEMO with the default resource"
  , "                   policy, and prints the template graph, per-template"
  , "                   polyphony, control surface, arbitration policy, and"
  , "                   CmdHotSwap projection. No audio, no RTGraph"
  , "                   allocation, no live reload."
  , "  --manifest-reload-plan-file MANIFEST.json DEMO"
  , "                   Diagnostic-only external manifest planning path."
  , "                   Reads MANIFEST.json as an AuthoringManifestDoc,"
  , "                   validates the selected DEMO against the built-in"
  , "                   authored-demo reload catalog, then prints the same"
  , "                   template/resource/control/arbitration/CmdHotSwap"
  , "                   diagnostic as --manifest-reload-plan. No audio,"
  , "                   no RTGraph allocation, no command enqueue, no live"
  , "                   reload."
  , "  --manifest-session-smoke MANIFEST.json DEMO"
  , "                   Construction-time manifest session smoke. Reads"
  , "                   MANIFEST.json, validates DEMO against the built-in"
  , "                   authored-demo reload catalog, constructs a fresh"
  , "                   SessionOwner from the plan, prints owner status and"
  , "                   graph/resource summary, then exits. No audio, no"
  , "                   CmdHotSwap execution, no live reload."
  , "  --manifest-stopped-audio-reload-smoke MANIFEST.json DEMO"
  , "                   Non-audio stopped-audio reload helper smoke. Reads"
  , "                   MANIFEST.json, validates DEMO against the built-in"
  , "                   authored-demo reload catalog, creates an existing"
  , "                   FanIn host from a built-in authored demo, calls"
  , "                   reloadManifestSessionStoppedAudio with the planned"
  , "                   owner, reports queue, reload, and owner status, then"
  , "                   exits. No audio start/stop, no listener restart,"
  , "                   no CmdHotSwap execution, no live reload."
  , "  --manifest-host-reload-smoke STRATEGY MANIFEST.json DEMO"
  , "                   Manual non-device host selector smoke. STRATEGY is"
  , "                   one of: " <> intercalate ", " manifestReloadHostStrategyNames
  , "                   Reads MANIFEST.json, validates DEMO against the"
  , "                   built-in authored-demo reload catalog, starts fake"
  , "                   host audio, runs reloadManifestHostWithStrategy,"
  , "                   reports whether preserving, stopped-audio, or"
  , "                   explicit fallback ran, then exits. No PortAudio"
  , "                   device is opened and the normal demo path is not"
  , "                   affected."
  , "  --manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW"
  , "                   Experimental audible manifest reload demo."
  , "                   STRATEGY is one of: "
      <> intercalate ", " manifestReloadHostStrategyNames
  , "                   Starts real audio from OLD, opens manifest-aware"
  , "                   OSC ingress, waits for Enter, reloads to NEW"
  , "                   through reloadManifestHostWithStrategy, then"
  , "                   waits for Enter before cleanup. Uses"
  , "                   --session-osc-port N for the OSC bind port."
  , "                   This is opt-in only; normal demo execution is"
  , "                   unchanged."
  , "  --manifest-midi-reload-smoke MANIFEST.json DEMO"
  , "                   Manual device-backed MIDI smoke for the manifest"
  , "                   MIDI ingress projection. Reads MANIFEST.json,"
  , "                   validates DEMO against the built-in authored-demo"
  , "                   reload catalog, opens a real PortMIDI input through"
  , "                   manifestPortMIDISourceFactory, and prints accepted"
  , "                   CC writes, manifest-layer rejects (unbound CC,"
  , "                   invalid byte, filtered channel), and ignored non-CC"
  , "                   events for the smoke window. Use --midi-device N to"
  , "                   pick a specific input; otherwise the first"
  , "                   input-capable device from --midi-list is selected."
  , "                   --manifest-midi-smoke-seconds N sets the window"
  , "                   (default 10 seconds). No audio start, no hot-swap"
  , "                   execution, no reload semantics; exits non-zero only"
  , "                   when the PortMIDI factory cannot produce an"
  , "                   input-capable source."
  , "  --manifest-midi-smoke-seconds N"
  , "                   Smoke window in seconds for"
  , "                   --manifest-midi-reload-smoke. Default 10."
  , "                   Ignored by other modes."
  , "  --summary        Switch --fusion-cost-lab output from JSONL to a"
  , "                   per-row summary table. Ignored by other modes."
  , "  --midi-list      Print Q / PortMIDI devices and exit. Device ids"
  , "                   with inputs can be passed to --midi-device."
  , "  --midi-device N  Select PortMIDI device id N for midi-poly,"
  , "                   --session-midi-smoke, or"
  , "                   --manifest-midi-reload-smoke. Use --midi-list to"
  , "                   discover ids. Ignored by non-MIDI modes."
  , "  --session-midi-smoke [SECONDS]"
  , "                   Manual non-audio probe for the session MIDI ingress"
  , "                   path. Opens the Q / PortMIDI source, feeds decoded"
  , "                   note-on, note-off, and CC 7 events through"
  , "                   MetaSonic.Session.MIDIListener and FanInService,"
  , "                   prints producer/drain activity, then exits non-zero"
  , "                   if no input device, no supported events, or no drained"
  , "                   session commands were observed. When --midi-device is"
  , "                   omitted, the first input-capable device is selected."
  , "                   Default window is 10 seconds; demo targets are ignored."
  , "  --session-osc-arbitration-smoke [SECONDS]"
  , "                   Manual non-audio probe for the explicit session OSC"
  , "                   arbitration path. Binds a UDP listener, routes decoded"
  , "                   packets through MetaSonic.Session.OSCListener and"
  , "                   FanInService with a TargetClaim policy on /v0/lpf/0,"
  , "                   and reports listener/service arbitration counters."
  , "                   Send /v0/lpf/0 to trigger policy rejection; send"
  , "                   /v1/lpf/0 to exercise normal fan-in drain. Default"
  , "                   window is 10 seconds; demo targets are ignored."
  , "  --session-osc-port N"
  , "                   UDP port for --session-osc-arbitration-smoke."
  , "                   Also used by --manifest-live-reload-demo."
  , "                   Default is 7001. Ignored by other modes."
  , "  --plugin-list    Print the build-linked static plugin registry"
  , "                   used by KStaticPlugin and exit. No audio, no TUI."
  , "  --osc-listen [PORT]"
  , "                   Phase 6.B.4 thin wrapper over"
  , "                   MetaSonic.OSC.Listen.withOscListener. Loads a"
  , "                   built-in demo graph"
  , "                   (SinOsc -> tagged \"outgain\" Gain -> Out 0),"
  , "                   starts realtime audio, and binds a UDP listener"
  , "                   on PORT (default 7000). Send OSC packets of the"
  , "                   form /v0/outgain/0 ,f <amount> to control the"
  , "                   gain. Press Enter to stop. Demo targets are"
  , "                   ignored."
  , ""
  , "Available demos:"
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
  , "  " <> prog <> " --midi-list"
  , "  " <> prog <> " --session-midi-smoke 10"
  , "  " <> prog <> " --midi-device 2 --session-midi-smoke 10"
  , "  " <> prog <> " --session-osc-arbitration-smoke 10"
  , "  " <> prog <> " --manifest-reload-plan send-return"
  , "  " <> prog <> " --manifest-reload-plan-file manifest.json send-return"
  , "  " <> prog <> " --manifest-session-smoke manifest.json send-return"
  , "  " <> prog <> " --manifest-stopped-audio-reload-smoke manifest.json send-return"
  , "  " <> prog <> " --manifest-host-reload-smoke try-preserving manifest.json send-return"
  , "  " <> prog <> " --manifest-live-reload-demo try-preserving manifest.json named-control named-control"
  , "  " <> prog <> " --manifest-midi-reload-smoke manifest.json send-return --midi-device 2"
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

  let resolveSelectedDemos = either die pure (resolveTargets (optTargets opts))
      runDemos banner = do
        demos <- resolveSelectedDemos
        putStrLn banner
        forM_ demos (runDemo opts)
        putStrLn "Done."

  case optMode opts of
    FusionSurvey -> do
      demos <- resolveSelectedDemos
      putStrLn "Surveying demos for §4.B / §4.C fusion coverage."
      runFusionSurvey demos
    WorkerBench -> do
      demos <- resolveSelectedDemos
      putStrLn "Benchmarking Haskell-loaded schedule worker modes."
      runWorkerBench demos
    SwapBench -> do
      putStrLn "Benchmarking Haskell hot-swap helper path."
      runSwapBench
    CorpusSurvey -> do
      putStrLn "Surveying the Phase 6.A pattern corpus for §4 signal."
      runCorpusSurvey
    FusionCostLab -> do
      let fcoOpts = FusionCostLabOptions
            { fcoFormat = if optFCLSummary opts
                            then FormatSummary
                            else FormatJSONL
            , fcoFamilies = fcoFamilies FCL.defaultOptions
            }
      runFusionCostLab fcoOpts
    SnapshotCheck ->
      runSnapshotCheck
    AuthoringManifest -> do
      demos <- resolveSelectedDemos
      runAuthoringManifest demos
    ManifestReloadDiagnostic -> do
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-reload-plan"
          "--manifest-reload-plan DEMO_KEY"
          opts
      runManifestReloadDiagnostic demo
    ManifestReloadFileDiagnostic -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-reload-plan-file")
        pure
        (optManifestReloadFile opts)
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-reload-plan-file"
          "--manifest-reload-plan-file MANIFEST.json DEMO_KEY"
          opts
      runManifestReloadFileDiagnostic manifestPath demo
    ManifestSessionSmoke -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-session-smoke")
        pure
        (optManifestReloadFile opts)
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-session-smoke"
          "--manifest-session-smoke MANIFEST.json DEMO_KEY"
          opts
      runManifestSessionSmoke manifestPath demo
    ManifestStoppedAudioReloadSmoke -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-stopped-audio-reload-smoke")
        pure
        (optManifestReloadFile opts)
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-stopped-audio-reload-smoke"
          "--manifest-stopped-audio-reload-smoke MANIFEST.json DEMO_KEY"
          opts
      result <- runManifestStoppedAudioReloadSmokeFile manifestPath demo
      case result of
        Left issue ->
          die (renderManifestReloadCliIssue issue)
        Right output ->
          putStr output
    ManifestHostStrategyReloadSmoke -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-host-reload-smoke")
        pure
        (optManifestReloadFile opts)
      strategy <- maybe
        (die "Missing strategy for --manifest-host-reload-smoke")
        pure
        (optManifestReloadHostStrategy opts)
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-host-reload-smoke"
          ("--manifest-host-reload-smoke "
           <> renderManifestReloadHostStrategy strategy
           <> " MANIFEST.json DEMO_KEY")
          opts
      result <-
        runManifestHostStrategyReloadSmokeFile
          strategy
          manifestPath
          demo
      case result of
        Left issue ->
          die (renderManifestReloadCliIssue issue)
        Right output ->
          putStr output
    ManifestLiveReloadDemo -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-live-reload-demo")
        pure
        (optManifestReloadFile opts)
      strategy <- maybe
        (die "Missing strategy for --manifest-live-reload-demo")
        pure
        (optManifestReloadHostStrategy opts)
      (oldDemo, newDemo) <- either die pure $
        resolveManifestLiveReloadTargets opts
      runManifestLiveReloadDemo
        strategy
        manifestPath
        oldDemo
        newDemo
        (defaultListenerConfig (optSessionOscPort opts))
    ManifestMIDIReloadSmoke -> do
      manifestPath <- maybe
        (die "Missing manifest JSON file for --manifest-midi-reload-smoke")
        pure
        (optManifestReloadFile opts)
      demo <- either die pure $
        resolveManifestReloadDiagnosticTarget
          "--manifest-midi-reload-smoke"
          "--manifest-midi-reload-smoke MANIFEST.json DEMO_KEY"
          opts
      runManifestMIDIReloadSmoke
        manifestPath
        demo
        (optMidiDevice opts)
        (optManifestMIDISmokeSeconds opts)
    OscListen ->
      runOscListen (optOscPort opts)
    MidiList ->
      printMidiDevices
    SessionMidiSmoke ->
      runSessionMidiSmoke
        (optMidiDevice opts)
        (optSessionMidiSmokeSeconds opts)
    SessionOscArbitrationSmoke ->
      runSessionOscArbitrationSmoke
        (optSessionOscSmokeSeconds opts)
        (optSessionOscPort opts)
    PluginList ->
      printPlugins
    AudioOnly      -> runDemos "Running selected demos."
    InspectThenRun -> runDemos "Inspecting selected demos before audio."
    InspectOnly    -> runDemos "Inspecting selected demos without audio."

-- Phase 8.H non-audio runner. Walks the selected demo
-- list, projects every 'demoAuthoring' report into a
-- manifest entry, wraps them in an
-- 'AuthoringManifestDoc' with the current schema
-- version, and writes pretty JSON to stdout. Demos
-- without authoring metadata are silently skipped so the
-- command stays script-friendly: a target list that
-- matches only legacy demos still produces a valid (but
-- empty) document rather than failing.
runAuthoringManifest :: [Demo] -> IO ()
runAuthoringManifest demos = do
  let manifests =
        [ manifestFromReport (demoKey d) r
        | d <- demos
        , Just r <- [demoAuthoring d]
        ]
      doc = AuthoringManifestDoc
        { docSchemaVersion = manifestSchemaVersion
        , docDemos         = manifests
        }
  BL.putStr (encodeManifestDoc doc)

-- Diagnostic-only app boundary for the manifest reload planner.
--
-- This exercises the product path from built-in demo registry to
-- app-owned catalog, expected manifest document, pure reload plan, and
-- runtime projection. It deliberately stops before allocating an RTGraph
-- or installing the projected command.
resolveManifestReloadDiagnosticTarget
  :: String
  -> String
  -> Options
  -> Either String Demo
resolveManifestReloadDiagnosticTarget flagName usageShape opts =
  case optTargets opts of
    [target] -> do
      demo <- first formatResolveError (resolveTargets [target]) >>= oneDemo
      case demoAuthoring demo of
        Just _ ->
          Right demo
        Nothing ->
          Left $
            "Demo '" <> demoKey demo <> "' has no authoring metadata; "
            <> flagName <> " requires an authored demo."
            <> "\nAuthored demos: "
            <> intercalate ", " authoredDemoKeys
    [] ->
      Left $
        "Specify exactly one demo: " <> usageShape
        <> "\nAuthored demos: "
        <> intercalate ", " authoredDemoKeys
    targets ->
      Left $
        "Specify exactly one demo for " <> flagName <> "; got "
        <> show (length targets)
        <> ": "
        <> intercalate ", " targets
  where
    authoredDemoKeys =
      [ demoKey d
      | d <- demoTable
      , Just _ <- [demoAuthoring d]
      ]

    oneDemo [demo] =
      Right demo
    oneDemo demos =
      Left $
        "Internal error: target resolution produced "
        <> show (length demos) <> " demos for " <> flagName <> "."

    formatResolveError err =
      err <> "\nAuthored demos: " <> intercalate ", " authoredDemoKeys

resolveManifestLiveReloadTargets :: Options -> Either String (Demo, Demo)
resolveManifestLiveReloadTargets opts =
  case optTargets opts of
    [oldKey, newKey] -> do
      oldDemo <- resolveAuthored oldKey
      newDemo <- resolveAuthored newKey
      Right (oldDemo, newDemo)
    [] ->
      Left $
        "Specify OLD and NEW demos: "
        <> "--manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW"
        <> "\nAuthored demos: "
        <> intercalate ", " authoredDemoKeys
    targets ->
      Left $
        "Specify exactly two demos for --manifest-live-reload-demo; got "
        <> show (length targets)
        <> ": "
        <> intercalate ", " targets
        <> "\nAuthored demos: "
        <> intercalate ", " authoredDemoKeys
  where
    authoredDemoKeys =
      [ demoKey d
      | d <- demoTable
      , Just _ <- [demoAuthoring d]
      ]

    resolveAuthored key = do
      demos <- first formatResolveError (resolveTargets [key])
      case demos of
        [demo]
          | Just _ <- demoAuthoring demo ->
              Right demo
          | otherwise ->
              Left $
                "Demo '" <> demoKey demo <> "' has no authoring metadata; "
                <> "--manifest-live-reload-demo requires authored demos."
                <> "\nAuthored demos: "
                <> intercalate ", " authoredDemoKeys
        _ ->
          Left $
            "Internal error: target resolution produced "
            <> show (length demos)
            <> " demos for --manifest-live-reload-demo."

    formatResolveError err =
      err <> "\nAuthored demos: " <> intercalate ", " authoredDemoKeys

runManifestReloadDiagnostic :: Demo -> IO ()
runManifestReloadDiagnostic demo = do
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  let doc = AuthoringManifestDoc
        { docSchemaVersion = manifestSchemaVersion
        , docDemos         = map MR.mrcManifest catalog
        }
  runManifestReloadDiagnosticWithDoc doc catalog demo

runManifestReloadFileDiagnostic :: FilePath -> Demo -> IO ()
runManifestReloadFileDiagnostic path demo = do
  doc <- readManifestReloadDoc path
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  runManifestReloadDiagnosticWithDoc doc catalog demo

runManifestSessionSmoke :: FilePath -> Demo -> IO ()
runManifestSessionSmoke path demo = do
  doc <- readManifestReloadDoc path
  catalog <- either die pure (demoManifestReloadCatalog demoTable)
  plan <- planManifestReloadOrDie doc catalog demo
  result <-
    constructManifestSessionFromPlan
      plan
      defaultSessionOwnerOptions
      $ \owner -> do
          state <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (state, status)
  case result of
    Left issue ->
      die $ "Manifest session construction failed: " <> show issue
    Right (state, status) ->
      printManifestSessionSmoke plan state status

readManifestReloadDoc :: FilePath -> IO AuthoringManifestDoc
readManifestReloadDoc path = do
  result <- readManifestReloadDocFile path
  case result of
    Left issue ->
      die (renderManifestReloadCliIssue issue)
    Right doc ->
      pure doc

runManifestReloadDiagnosticWithDoc
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO ()
runManifestReloadDiagnosticWithDoc doc catalog demo = do
  plan <- planManifestReloadOrDie doc catalog demo
  printManifestReloadPlan plan

planManifestReloadOrDie
  :: AuthoringManifestDoc
  -> [MR.ManifestReloadCatalogEntry]
  -> Demo
  -> IO MR.ManifestReloadPlan
planManifestReloadOrDie doc catalog demo = do
  let request = MR.ManifestReloadRequest
        { MR.mrrDemoKey        = demoKey demo
        , MR.mrrSwapLabel      = SwapLabel ("manifest:" <> demoKey demo)
        , MR.mrrResourcePolicy = MR.defaultManifestResourcePolicy
        }
  case MR.planManifestReload doc catalog request of
    Left issue ->
      die $ "Manifest reload planning failed: " <> show issue
    Right plan ->
      pure plan

printManifestReloadPlan :: MR.ManifestReloadPlan -> IO ()
printManifestReloadPlan plan = do
  putStrLn "Manifest reload plan diagnostic"
  putStrLn $ "  demo: " <> MR.mrlpDemoKey plan
  putStrLn $ "  swap label: " <> swapLabelText (MR.mrlpSwapLabel plan)
  printManifestReloadTemplates (MR.mrlpTemplateGraph plan)
  printManifestReloadResources (MR.mrlpAdapterOptions plan)
  printManifestReloadControls (MR.mrlpControlSurface plan)
  putStrLn $ "  arbitration policy: "
          <> show (MR.mrlpArbitrationPolicy plan)
  printManifestReloadCommand (MR.manifestReloadCommand plan)

printManifestSessionSmoke
  :: MR.ManifestReloadPlan
  -> SessionState
  -> SessionOwnerStatus
  -> IO ()
printManifestSessionSmoke plan state status = do
  putStrLn "Manifest session construction smoke"
  putStrLn $ "  demo: " <> MR.mrlpDemoKey plan
  putStrLn $ "  swap label: " <> swapLabelText (MR.mrlpSwapLabel plan)
  printManifestReloadTemplates (MR.mrlpTemplateGraph plan)
  printManifestReloadResources (MR.mrlpAdapterOptions plan)
  putStrLn $ "  owner status: " <> show status
  putStrLn $
    "  graph installed: "
    <> if ssGraph state == MR.mrlpTemplateGraph plan
          then "yes"
          else "no"
  putStrLn $ "  active voices: " <> show (M.size (ssVoices state))
  putStrLn "  audio started: no"
  putStrLn "  command projection: not executed"

printManifestReloadTemplates :: TemplateGraph -> IO ()
printManifestReloadTemplates graph = do
  putStrLn "  template graph:"
  putStrLn $ "    templates: " <> show (length (tgTemplates graph))
  forM_ (tgTemplates graph) $ \tpl ->
    putStrLn $
      "    - "
      <> tplName tpl
      <> " nodes="
      <> show (length (rgNodes (tplGraph tpl)))

printManifestReloadResources :: RTGraphAdapterOptions -> IO ()
printManifestReloadResources opts = do
  putStrLn "  resource policy projection:"
  putStrLn $
    "    default polyphony: " <> show (raoDefaultPolyphony opts)
  putStrLn $
    "    hot-swap install timeout ms: "
    <> show (raoHotSwapInstallTimeoutMs opts)
  putStrLn "    per-template polyphony:"
  case M.toList (raoPerTemplatePolyphony opts) of
    [] ->
      putStrLn "      (none)"
    rows ->
      forM_ rows $ \(TemplateName name, polyphony) ->
        putStrLn $
          "      - " <> name <> ": " <> show polyphony

printManifestReloadControls :: [MR.ManifestControlSurface] -> IO ()
printManifestReloadControls controls = do
  putStrLn "  control surface:"
  case controls of
    [] ->
      putStrLn "    (none)"
    _ ->
      forM_ controls $ \control ->
        putStrLn $
          "    - "
          <> MR.mcsDisplayName control
          <> ": tag="
          <> controlTagText (MR.mcsControlTag control)
          <> " default="
          <> show (MR.mcsDefault control)
          <> " range=["
          <> show (MR.mcsRangeMin control)
          <> ", "
          <> show (MR.mcsRangeMax control)
          <> "] smoothingHz="
          <> show (MR.mcsSmoothingHz control)
          <> " cc="
          <> maybe "none" show (MR.mcsCC control)

printManifestReloadCommand :: SessionCommand -> IO ()
printManifestReloadCommand command =
  case command of
    CmdHotSwap label graph ->
      putStrLn $
        "  command projection: CmdHotSwap "
        <> swapLabelText label
        <> " templates="
        <> show (length (tgTemplates graph))
        <> " (not executed)"
    CmdHotSwapPreservingOnly label graph ->
      putStrLn $
        "  command projection: CmdHotSwapPreservingOnly "
        <> swapLabelText label
        <> " templates="
        <> show (length (tgTemplates graph))
        <> " (not executed)"
    _ ->
      putStrLn $
        "  command projection: "
        <> show command
        <> " (not executed)"

swapLabelText :: SwapLabel -> String
swapLabelText =
  unSwapLabel

controlTagText :: ControlTag -> String
controlTagText (ControlTag key slot) =
  unMigrationKey key <> "/" <> show slot

printMidiDevices :: IO ()
printMidiDevices = do
  result <- midiDeviceList
  case result of
    Left err -> die err
    Right [] -> do
      putStrLn "No MIDI devices reported by Q / PortMIDI."
      putStrLn "On Linux, check that ALSA sequencer support is available."
    Right devices -> do
      putStrLn "MIDI devices reported by Q / PortMIDI:"
      forM_ devices $ \d -> do
        let usable = if midiDeviceInputs d > 0
                       then "input"
                       else "no input"
        putStrLn $
          "  id=" <> show (midiDeviceId d)
          <> "  inputs=" <> show (midiDeviceInputs d)
          <> "  outputs=" <> show (midiDeviceOutputs d)
          <> "  " <> usable
          <> "  name=\"" <> midiDeviceName d <> "\""
      putStrLn ""
      putStrLn "Use an input-capable id with --midi-device N for midi-poly,"
      putStrLn "--session-midi-smoke, or --manifest-midi-reload-smoke."

printPlugins :: IO ()
printPlugins = do
  entries <- pluginRegistryEntries
  case entries of
    [] ->
      putStrLn "No static plugins registered."
    _ -> do
      putStrLn "Static plugins:"
      forM_ entries $ \p ->
        putStrLn $
          "  id=" <> show (pluginEntryId p)
          <> "  name=\"" <> pluginEntryName p <> "\""
          <> "  audio_inputs=" <> show (pluginEntryAudioInputs p)
          <> "  audio_outputs=" <> show (pluginEntryAudioOutputs p)
          <> "  latency_samples=" <> show (pluginEntryLatencySamples p)
          <> "  state_bytes=" <> show (pluginEntryStateBytes p)

-- Top-level dispatch: route a Demo to its body-specific runner. See
-- Note [Demo body: single-graph vs multi-template].
runDemo :: Options -> Demo -> IO ()
runDemo opts demo
  -- 'main' routes reporting modes before 'runDemo' is reached.
  -- Guard the dispatch boundary explicitly so a future re-routing
  -- mistake fails loudly here, rather than silently running audio.
  -- The single guard covers all three body-specific runners.
  | optMode opts == FusionSurvey
    || optMode opts == WorkerBench
    || optMode opts == SwapBench
    || optMode opts == CorpusSurvey
    || optMode opts == FusionCostLab
    || optMode opts == SnapshotCheck
    || optMode opts == OscListen
    || optMode opts == MidiList
    || optMode opts == SessionMidiSmoke
    || optMode opts == SessionOscArbitrationSmoke
    || optMode opts == PluginList
    || optMode opts == AuthoringManifest
    || optMode opts == ManifestReloadDiagnostic
    || optMode opts == ManifestReloadFileDiagnostic
    || optMode opts == ManifestSessionSmoke
    || optMode opts == ManifestStoppedAudioReloadSmoke
    || optMode opts == ManifestHostStrategyReloadSmoke
    || optMode opts == ManifestLiveReloadDemo
    || optMode opts == ManifestMIDIReloadSmoke =
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
      printAuthoringMetadata demo
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
    SwapBench ->
      error "runSingleDemo: SwapBench should be handled by main, never reach here"
    CorpusSurvey ->
      error "runSingleDemo: CorpusSurvey should be handled by main, never reach here"
    FusionCostLab ->
      error "runSingleDemo: FusionCostLab should be handled by main, never reach here"
    SnapshotCheck ->
      error "runSingleDemo: SnapshotCheck should be handled by main, never reach here"
    OscListen ->
      error "runSingleDemo: OscListen should be handled by main, never reach here"
    MidiList ->
      error "runSingleDemo: MidiList should be handled by main, never reach here"
    SessionMidiSmoke ->
      error "runSingleDemo: SessionMidiSmoke should be handled by main, never reach here"
    SessionOscArbitrationSmoke ->
      error "runSingleDemo: SessionOscArbitrationSmoke should be handled by main, never reach here"
    PluginList ->
      error "runSingleDemo: PluginList should be handled by main, never reach here"
    AuthoringManifest ->
      error "runSingleDemo: AuthoringManifest should be handled by main, never reach here"
    ManifestReloadDiagnostic ->
      error "runSingleDemo: ManifestReloadDiagnostic should be handled by main, never reach here"
    ManifestReloadFileDiagnostic ->
      error "runSingleDemo: ManifestReloadFileDiagnostic should be handled by main, never reach here"
    ManifestSessionSmoke ->
      error "runSingleDemo: ManifestSessionSmoke should be handled by main, never reach here"
    ManifestStoppedAudioReloadSmoke ->
      error "runSingleDemo: ManifestStoppedAudioReloadSmoke should be handled by main, never reach here"
    ManifestHostStrategyReloadSmoke ->
      error "runSingleDemo: ManifestHostStrategyReloadSmoke should be handled by main, never reach here"
    ManifestLiveReloadDemo ->
      error "runSingleDemo: ManifestLiveReloadDemo should be handled by main, never reach here"
    ManifestMIDIReloadSmoke ->
      error "runSingleDemo: ManifestMIDIReloadSmoke should be handled by main, never reach here"

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
          printAuthoringMetadata demo
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
                               poly (optMidiDevice opts) tg vm ccs mpb
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
  -> Maybe Int                 -- ^ PortMIDI device id
  -> TemplateGraph
  -> VoiceMapping
  -> [CCMapping]
  -> Maybe PitchBendBinding
  -> IO ()
runMidiPolyAudio capacity poly midiDevice tg vm ccs mpb =
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
            <> ", MIDI device="
            <> maybe "default (0)" show midiDevice
            <> "; opening MIDI session..."

    withMidiDemo rt 0 poly midiDevice vm ccs mpb 0xFFFF $ \mh ->
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
    let fp = rfBuses (tplFootprint t)
    putStrLn $
      "    " <> show i <> ". " <> tplName t
      <> "  writes=" <> show (bfWrites fp)
      <> "  live-reads=" <> show (bfReads fp)
      <> "  delayed-reads=" <> show (bfDelayedReads fp)

-- Emit the Phase 8.G authoring metadata block for a demo
-- that opts in. Silent when 'demoAuthoring demo = Nothing',
-- so legacy demos keep their existing output unchanged.
-- The library-side 'renderAuthoringReport' does the pure
-- formatting; this wrapper just prints the lines.
printAuthoringMetadata :: Demo -> IO ()
printAuthoringMetadata =
  mapM_ putStrLn . renderAuthoringReport . demoAuthoring

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
