{-# LANGUAGE LambdaCase #-}

-- | Session command, runtime ownership, queue, host, MIDI, and OSC producer tests.
module MetaSonic.Spec.Session where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import qualified Data.Text                 as T
import           Data.List                 (isInfixOf, sort)
import           Control.Concurrent        (MVar, forkIO, newEmptyMVar, putMVar,
                                            takeMVar, threadDelay)
import           Control.Exception         (SomeException, displayException,
                                            evaluate, try)
import           Control.Monad             (forM, forM_)
import           Data.Maybe                (listToMaybe, mapMaybe)
import           Data.Word                 (Word16, Word8)
import           Data.IORef                (modifyIORef', newIORef, readIORef,
                                            writeIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Buffer
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import           MetaSonic.ControlTarget
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Report
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Session.RTGraphAdapter
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.PatternProducer
import           MetaSonic.Session.Runner
import           MetaSonic.Session.Host
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.MIDIProducer
import qualified MetaSonic.Session.MIDIListener as MIDIS
import qualified MetaSonic.Session.MIDIPortMIDI as MIDIPM
import           MetaSonic.Session.OSCProducer
import qualified MetaSonic.Session.OSCListener as OSCS
import           MetaSonic.Session.UIProducer
import           MetaSonic.Types
import           MetaSonic.Spec.Core

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC

------------------------------------------------------------
-- Session Prep A: command/event vocabulary
--
-- These tests pin only the structural adapter from the existing
-- pattern producer vocabulary into the future session vocabulary.
-- No command execution, queue writes, or runtime ownership is implied.
------------------------------------------------------------

sessionCommandTests :: TestTree
sessionCommandTests = testGroup "Session Prep A: command vocabulary"
  [ testCase "PEVoiceOn adapts to CmdVoiceOn" $ do
      let tname = TemplateName "voice"
          vkey  = VoiceKey "v0"
          ctrls =
            [ (ControlTag (MigrationKey "freq") 0, 440.0)
            , (ControlTag (MigrationKey "amp")  1, 0.25)
            ]
      fromPatternEvent (PEVoiceOn tname vkey ctrls)
        @?= CmdVoiceOn tname vkey ctrls

  , testCase "PEVoiceOff adapts to CmdVoiceOff" $ do
      let vkey = VoiceKey "v0"
      fromPatternEvent (PEVoiceOff vkey)
        @?= CmdVoiceOff vkey

  , testCase "PEControlWrite adapts to CmdControlWrite" $ do
      let vkey   = VoiceKey "v0"
          target = ControlTag (MigrationKey "cutoff") 0
      fromPatternEvent (PEControlWrite vkey target 1200.0)
        @?= CmdControlWrite vkey target 1200.0

  , testCase "PEHotSwap adapts to CmdHotSwap and preserves payload" $ do
      let swapLabel = SwapLabel "edit-cutoff"
          tg        = patternTemplates hotSwapEdit
      fromPatternEvent (PEHotSwap swapLabel tg)
        @?= CmdHotSwap swapLabel tg

  , testCase "diagnostic events are structural values, not execution" $ do
      let cmd   = CmdVoiceOff (VoiceKey "stale")
          issue = SiStaleVoice (VoiceKey "stale")
      SessionCommandRejected cmd issue
        @?= SessionCommandRejected cmd issue
  ]

------------------------------------------------------------
-- Session Prep A: OSC resolve-state rebuild
--
-- These tests pin the pure rebuild policy a future session owner will
-- use after a successful graph install. The helper rebuilds symbolic
-- OSC resolution only; it does not install graphs or touch RTGraph.
------------------------------------------------------------

sessionResolveTests :: TestTree
sessionResolveTests = testGroup "Session Prep A: resolve rebuild"
  [ testCase "valid binding survives rebuild" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result @?= []
      OSC.resolveStateVoices (rrrState result)
        @?= M.fromList [(OBSC.pack "v0", (7, OBSC.pack "drone"))]

  , testCase "missing template binding is dropped" $ do
      let tg = patternTemplates polyphonicStab
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result
        @?= [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      OSC.resolveStateVoices (rrrState result) @?= M.empty

  , testCase "invalid voice key is dropped through OSC validation" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "bad/key"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
      rrrDropped result
        @?= [ RriInvalidVoiceKey
                (VoiceKey "bad/key")
                (OSC.DiIdentifierProfile (OBSC.pack "bad/key"))
            ]
      OSC.resolveStateVoices (rrrState result) @?= M.empty

  , testCase "dropped binding diagnostics preserve input order" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding (VoiceKey "gone")    1 (TemplateName "missing")
            , VoiceBinding (VoiceKey "bad/key") 2 (TemplateName "drone")
            , VoiceBinding (VoiceKey "v0")      3 (TemplateName "drone")
            ]
      rrrDropped result
        @?= [ RriMissingTemplate (VoiceKey "gone") (TemplateName "missing")
            , RriInvalidVoiceKey
                (VoiceKey "bad/key")
                (OSC.DiIdentifierProfile (OBSC.pack "bad/key"))
            ]
      OSC.resolveStateVoices (rrrState result)
        @?= M.fromList [(OBSC.pack "v0", (3, OBSC.pack "drone"))]

  , testCase "retained binding resolves through rebuilt state" $ do
      let tg = patternTemplates droneVibrato
          result = rebuildResolveState tg
            [ VoiceBinding
                { vbVoiceKey     = VoiceKey "v0"
                , vbSlotId       = 7
                , vbTemplateName = TemplateName "drone"
                }
            ]
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                               [OSC.OscArgFloat 1800.0]
      rrrDropped result @?= []
      case OSC.dispatch (rrrState result) msg of
        Right (OSC.DAControlWrite
                  { OSC.daSlotId     = slotId
                  , OSC.daNodeIndex  = nodeIx
                  , OSC.daControlIdx = ctrlIx
                  , OSC.daValue      = value
                  }) -> do
          slotId @?= 7
          ctrlIx @?= 0
          value @?= 1800.0
          let lpfTargets =
                [ rnIndex n
                | tpl <- tgTemplates tg
                , tplName tpl == "drone"
                , n   <- rgNodes (tplGraph tpl)
                , rnMigrationKey n == Just (MigrationKey "lpf")
                ]
          assertBool
            ("expected lpf target, got " <> show nodeIx
             <> " from " <> show lpfTargets)
            (nodeIx `elem` lpfTargets)
        other ->
          assertFailure ("expected control-write dispatch, got: " <> show other)
  ]

------------------------------------------------------------
-- Session Prep A: lifecycle reports
--
-- These tests pin the read-only reporting surface that a future
-- session owner can render or log outside the audio thread. The
-- module reads existing counters/metadata only.
------------------------------------------------------------

sessionReportTests :: TestTree
sessionReportTests = testGroup "Session Prep A: lifecycle reports"
  [ testCase "fresh report starts with zero counters and static plugins" $
      withRTGraph 4 64 $ \rt -> do
        report <- readSessionLifecycleReport rt
        slrBuffers report @?= BufferLifecycleReport 0 0 0 0
        plrCallCount (slrPlugins report) @?= 0
        plrInvalidCallCount (slrPlugins report) @?= 0
        assertBool
          ("expected identity plugin in registry: "
           <> show (plrRegistered (slrPlugins report)))
          (any ((== "identity") . pluginEntryName)
               (plrRegistered (slrPlugins report)))

  , testCase "plugin report observes identity dispatch counters" $ do
      let nframes = 64
          graph = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sinOsc 220.0 0.0
            y <- staticPlugin identityPlugin a b
            out 0 y
      tg <- case compileTemplateGraph [("plugin", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        before <- readPluginLifecycleReport rt
        plrCallCount before @?= 0
        plrInvalidCallCount before @?= 0

        c_rt_graph_process rt (fromIntegral nframes)
        pluginAfter <- readPluginLifecycleReport rt
        plrCallCount pluginAfter @?= 1
        plrInvalidCallCount pluginAfter @?= 0
        assertBool
          "plugin registry should remain visible after processing"
          (any ((== "identity") . pluginEntryName)
               (plrRegistered pluginAfter))

  , testCase "buffer report observes invalid read counters" $ do
      let nframes = 32
          graph = runSynth $ do
            s <- playBufMono (Buffer 99) (Param 1.0) (Param 0) (Param 0)
            out 0 s
      rtGraph <- case lowerGraph graph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"
      withRTGraph (length (rgNodes rtGraph)) nframes $ \rt -> do
        loadRuntimeGraph rt rtGraph
        c_rt_graph_process rt (fromIntegral nframes)
        report <- readBufferLifecycleReport rt
        blrReadCount report @?= 0
        blrInvalidReadCount report @?= fromIntegral nframes
        blrWriteCount report @?= 0
        blrInvalidWriteCount report @?= 0

  , testCase "buffer report observes recordBufMono write counters" $ do
      let nframes = 64
          graph = runSynth $ do
            mon <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            out 0 mon
      tg <- case compileTemplateGraph [("record", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf (replicate nframes 0.0)
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        report <- readBufferLifecycleReport rt
        blrReadCount report @?= 0
        blrInvalidReadCount report @?= 0
        blrWriteCount report @?= fromIntegral nframes
        blrInvalidWriteCount report @?= 0
  ]

------------------------------------------------------------
-- Session Prep B/C: pure admission, commit state, and handshake
--
-- These tests pin the split between read-only command admission
-- and state-changing commits, plus the Prep C checked plan/commit
-- handshake. They do not allocate runtime voices, install graphs,
-- write queues, or touch RTGraph.
------------------------------------------------------------

sessionStateTests :: TestTree
sessionStateTests = testGroup "Session Prep B/C: admission, commits, and handshake"
  [ testCase "initial state accepts an empty graph as boot state" $ do
      let bootGraph = TemplateGraph [] M.empty
          st  = initialSessionState bootGraph
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      ssGraph st @?= bootGraph
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty
      admitSessionCommand cmd st
        @?= SessionRejected cmd (SiUnknownTemplate (TemplateName "drone"))

  , testCase "known-template voice start plans without mutating state" $ do
      let tg       = patternTemplates droneVibrato
          st       = initialSessionState tg
          controls = [(ControlTag (MigrationKey "amp") 0, 0.25)]
          cmd      = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") controls
      admitSessionCommand cmd st
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") controls)
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty

  , testCase "admitted voice start has no effect without commit" $ do
      let tg  = patternTemplates droneVibrato
          st  = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          off = CmdVoiceOff (VoiceKey "v0")
      admitSessionCommand cmd st
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") [])
      -- Simulated runtime failure: no CommitVoiceStarted is applied.
      ssVoices st @?= M.empty
      OSC.resolveStateVoices (ssResolve st) @?= M.empty
      admitSessionCommand off st
        @?= SessionRejected off (SiStaleVoice (VoiceKey "v0"))

  , testCase "unknown template and malformed keys reject at admission" $ do
      let st = initialSessionState (patternTemplates droneVibrato)
          unknown =
            CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
          malformed =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "bad/key") []
          reserved =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "swap") []
      admitSessionCommand unknown st
        @?= SessionRejected unknown (SiUnknownTemplate (TemplateName "missing"))
      admitSessionCommand malformed st
        @?= SessionRejected malformed (SiInvalidVoiceKey (VoiceKey "bad/key"))
      admitSessionCommand reserved st
        @?= SessionRejected reserved (SiInvalidVoiceKey (VoiceKey "swap"))

  , testCase "voice-start commit inserts binding and resolve entry" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding
            { vbVoiceKey     = VoiceKey "v0"
            , vbSlotId       = 11
            , vbTemplateName = TemplateName "drone"
            }
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
      ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
      OSC.resolveStateVoices (ssResolve st1)
        @?= M.fromList [(OBSC.pack "v0", (11, OBSC.pack "drone"))]

  , testCase "voice-start commit rejects invalid runtime binding loudly" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "bad/key") 11 (TemplateName "drone")
      thrown <- try (evaluate (applySessionCommit (CommitVoiceStarted binding) st0))
                  :: IO (Either SomeException SessionState)
      case thrown of
        Left ex ->
          assertBool
            "exception should explain the SessionCommit invariant"
            ("invariant violated" `isInfixOf` displayException ex)
        Right _ ->
          assertFailure "expected invalid committed binding to fail loudly"

  , testCase "duplicate active voice rejects after start commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      admitSessionCommand cmd st1
        @?= SessionRejected cmd (SiVoiceAlreadyActive (VoiceKey "v0"))

  , testCase "voice off and control write plan only for active voices" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          target = ControlTag (MigrationKey "lpf") 0
          off = CmdVoiceOff (VoiceKey "v0")
          write = CmdControlWrite (VoiceKey "v0") target 1800.0
          staleOff = CmdVoiceOff (VoiceKey "missing")
          staleWrite = CmdControlWrite (VoiceKey "missing") target 1800.0
      admitSessionCommand off st1
        @?= SessionAdmitted off (PlanVoiceStop binding)
      admitSessionCommand write st1
        @?= SessionAdmitted write (PlanControlWrite binding target 1800.0)
      admitSessionCommand staleOff st1
        @?= SessionRejected staleOff (SiStaleVoice (VoiceKey "missing"))
      admitSessionCommand staleWrite st1
        @?= SessionRejected staleWrite (SiStaleVoice (VoiceKey "missing"))

  , testCase "voice-stop commit removes binding and resolve entry" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          st2 = applySessionCommit (CommitVoiceStopped (VoiceKey "v0")) st1
      ssVoices st2 @?= M.empty
      OSC.resolveStateVoices (ssResolve st2) @?= M.empty

  , testCase "hot-swap admission previews drops without installing graph" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap (SwapLabel "remove-drone") newGraph
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ (PlanHotSwap _ graph preview) -> do
          graph @?= newGraph
          rrrDropped preview @?= expectedDrop
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)
      ssGraph st0 @?= oldGraph
      OSC.resolveStateTemplate (ssResolve st0) @?= oldGraph

  , testCase "graph-install commit reports authoritative drops" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding0 = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          binding1 = VoiceBinding (VoiceKey "v1") 12 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding0)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap (SwapLabel "remove-drone") newGraph
          previewDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
          commitDrop =
            [ RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")
            , RriMissingTemplate (VoiceKey "v1") (TemplateName "drone")
            ]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ (PlanHotSwap _ _ preview) ->
          rrrDropped preview @?= previewDrop
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)
      let st1 = applySessionCommit (CommitVoiceStarted binding1) st0
          (st2, committed) =
            commitGraphInstalled (SwapLabel "remove-drone") newGraph st1
      rrrDropped committed @?= commitDrop
      ssVoices st2 @?= M.empty
      OSC.resolveStateTemplate (ssResolve st2) @?= newGraph

  , testCase "graph-install commit rebuilds resolve and drops missing voices" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          (st1, result) =
            commitGraphInstalled (SwapLabel "remove-drone") newGraph st0
      ssGraph st1 @?= newGraph
      ssVoices st1 @?= M.empty
      OSC.resolveStateTemplate (ssResolve st1) @?= newGraph
      OSC.resolveStateVoices (ssResolve st1) @?= M.empty
      rrrDropped result
        @?= [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]

  , testCase "graph-install commit preserves surviving voices" $ do
      let graph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 11 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState graph)
          (st1, result) = commitGraphInstalled (SwapLabel "same") graph st0
      ssGraph st1 @?= graph
      ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
      OSC.resolveStateVoices (ssResolve st1)
        @?= M.fromList [(OBSC.pack "v0", (11, OBSC.pack "drone"))]
      rrrDropped result @?= []

  , testCase "planned voice-start accepts matching commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          plan = PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") []
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          commit = CommitVoiceStarted binding
      case applyPlannedCommit plan commit st0 of
        Right (st1, result) -> do
          result @?= Nothing
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
          OSC.resolveStateVoices (ssResolve st1)
            @?= M.fromList [(OBSC.pack "v0", (21, OBSC.pack "drone"))]
        Left issue ->
          assertFailure ("expected planned voice-start commit, got: " <> show issue)

  , testCase "planned voice-start rejects mismatches without mutation" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          plan = PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") []
          wrongKeyBinding =
            VoiceBinding (VoiceKey "v1") 21 (TemplateName "drone")
          wrongKey = CommitVoiceStarted wrongKeyBinding
          wrongTemplate = CommitVoiceStarted
            (VoiceBinding (VoiceKey "v0") 21 (TemplateName "other"))
          wrongCtor = CommitVoiceStopped (VoiceKey "v0")
      applyPlannedCommit plan wrongKey st0
        @?= Left (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))
      applyPlannedCommit plan wrongTemplate st0
        @?= Left (SciTemplateMismatch (TemplateName "drone") (TemplateName "other"))
      applyPlannedCommit plan wrongCtor st0
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongKey = applySessionCommit wrongKey st0
      ssVoices directWrongKey @?= M.fromList [(VoiceKey "v1", wrongKeyBinding)]
      OSC.resolveStateVoices (ssResolve directWrongKey)
        @?= M.fromList [(OBSC.pack "v1", (21, OBSC.pack "drone"))]

  , testCase "planned voice-stop accepts matching commit" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          plan = PlanVoiceStop binding
          commit = CommitVoiceStopped (VoiceKey "v0")
      case applyPlannedCommit plan commit st1 of
        Right (st2, result) -> do
          result @?= Nothing
          ssVoices st2 @?= M.empty
          OSC.resolveStateVoices (ssResolve st2) @?= M.empty
        Left issue ->
          assertFailure ("expected planned voice-stop commit, got: " <> show issue)

  , testCase "planned voice-stop rejects mismatches without mutation" $ do
      let st0 = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st1 = applySessionCommit (CommitVoiceStarted binding) st0
          plan = PlanVoiceStop binding
          wrongKey = CommitVoiceStopped (VoiceKey "v1")
          wrongStartBinding =
            VoiceBinding (VoiceKey "v0") 22 (TemplateName "drone")
          wrongCtor = CommitVoiceStarted wrongStartBinding
      applyPlannedCommit plan wrongKey st1
        @?= Left (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))
      applyPlannedCommit plan wrongCtor st1
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongCtor = applySessionCommit wrongCtor st1
      ssVoices directWrongCtor
        @?= M.fromList [(VoiceKey "v0", wrongStartBinding)]
      OSC.resolveStateVoices (ssResolve directWrongCtor)
        @?= M.fromList [(OBSC.pack "v0", (22, OBSC.pack "drone"))]

  , testCase "planned control-write rejects all state commits" $ do
      let graph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          plan = PlanControlWrite
            binding
            (ControlTag (MigrationKey "lpf") 0)
            1800.0
          commits =
            [ CommitVoiceStarted binding
            , CommitVoiceStopped (VoiceKey "v0")
            , CommitGraphInstalled (SwapLabel "same") graph
            ]
      forM_ commits $ \commit ->
        applyPlannedCommit plan commit (initialSessionState graph)
          @?= Left SciControlPlanHasNoStateCommit

  , testCase "planned hot-swap returns authoritative commit-time rebuild" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapLabel = SwapLabel "remove-drone"
          binding0 = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          binding1 = VoiceBinding (VoiceKey "v1") 22 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding0)
                  (initialSessionState oldGraph)
          cmd = CmdHotSwap swapLabel newGraph
          expectedPreview =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
          expectedCommit =
            [ RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")
            , RriMissingTemplate (VoiceKey "v1") (TemplateName "drone")
            ]
      case admitSessionCommand cmd st0 of
        SessionAdmitted _ plan@(PlanHotSwap _ _ preview) -> do
          rrrDropped preview @?= expectedPreview
          let st1 = applySessionCommit (CommitVoiceStarted binding1) st0
              commit = CommitGraphInstalled swapLabel newGraph
          case applyPlannedCommit plan commit st1 of
            Right (st2, Just committed) -> do
              rrrDropped committed @?= expectedCommit
              ssGraph st2 @?= newGraph
              ssVoices st2 @?= M.empty
            other ->
              assertFailure ("expected planned hot-swap commit, got: " <> show other)
        other ->
          assertFailure ("expected hot-swap plan, got: " <> show other)

  , testCase "planned hot-swap rejects mismatches without mutation" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapLabel = SwapLabel "remove-drone"
          wrongLabel = SwapLabel "other"
          binding = VoiceBinding (VoiceKey "v0") 21 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          plan = PlanHotSwap swapLabel newGraph (rebuildResolveState newGraph [binding])
          wrongLabelCommit = CommitGraphInstalled wrongLabel newGraph
          wrongGraphCommit = CommitGraphInstalled swapLabel oldGraph
          wrongCtor = CommitVoiceStopped (VoiceKey "v0")
      applyPlannedCommit plan wrongLabelCommit st0
        @?= Left (SciSwapLabelMismatch swapLabel wrongLabel)
      applyPlannedCommit plan wrongGraphCommit st0
        @?= Left SciGraphMismatch
      applyPlannedCommit plan wrongCtor st0
        @?= Left (SciUnexpectedCommit plan wrongCtor)
      let directWrongLabel = applySessionCommit wrongLabelCommit st0
      ssGraph directWrongLabel @?= newGraph
      ssVoices directWrongLabel @?= M.empty
      OSC.resolveStateVoices (ssResolve directWrongLabel) @?= M.empty
  ]

------------------------------------------------------------
-- Session Prep D: runtime adapter shell and orchestrator
--
-- These tests pin 'stepSessionCommand' against mock
-- 'SessionRuntimeAdapter' implementations. No RTGraph, audio backend,
-- or realtime queue is touched; the real adapter belongs to a later
-- slice and must satisfy the same contract.
------------------------------------------------------------

constantAdapter
  :: Applicative m
  => Either SessionRuntimeIssue SessionRuntimeSuccess
  -> SessionRuntimeAdapter m
constantAdapter outcome =
  SessionRuntimeAdapter $ \_ -> pure outcome

sessionStepTests :: TestTree
sessionStepTests = testGroup "Session Prep D: runtime adapter shell"
  [ testCase "admission rejection does not call the runtime adapter" $ do
      counter <- newIORef (0 :: Int)
      let adapter = SessionRuntimeAdapter $ \_ -> do
            modifyIORef' counter (+1)
            pure (Left SriBackendStopped)
          st  = initialSessionState (patternTemplates droneVibrato)
          cmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st
      result @?= StepRejected (SiUnknownTemplate (TemplateName "missing"))
      calls <- readIORef counter
      calls @?= 0

  , testCase "voice-start success commits the runtime VoiceBinding" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          adapter = constantAdapter
                      (Right (RuntimeCommitted (CommitVoiceStarted binding)))
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 rebuild -> do
          rebuild @?= Nothing
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
          OSC.resolveStateVoices (ssResolve st1)
            @?= M.fromList [(OBSC.pack "v0", (17, OBSC.pack "drone"))]
        other ->
          assertFailure ("expected StepCommitted, got: " <> show other)

  , testCase "voice-start runtime failure leaves state unchanged" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          adapter = constantAdapter (Left SriVoiceAllocationFailed)
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      result @?= StepRuntimeFailed SriVoiceAllocationFailed
      admitSessionCommand cmd st0
        @?= SessionAdmitted cmd
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v0") [])

  , testCase "wrong runtime commit surfaces as StepCommitMismatch" $ do
      let st0       = initialSessionState (patternTemplates droneVibrato)
          wrongBind = VoiceBinding (VoiceKey "v1") 17 (TemplateName "drone")
          adapter   = constantAdapter
                        (Right (RuntimeCommitted (CommitVoiceStarted wrongBind)))
          cmd       = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      result @?= StepCommitMismatch
                   (SciVoiceKeyMismatch (VoiceKey "v0") (VoiceKey "v1"))

  , testCase "control-write success leaves SessionState unchanged" $ do
      let graph   = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0     = applySessionCommit
                      (CommitVoiceStarted binding)
                      (initialSessionState graph)
          adapter = constantAdapter (Right RuntimeControlWriteAccepted)
          cmd     = CmdControlWrite
                      (VoiceKey "v0")
                      (ControlTag (MigrationKey "lpf") 0)
                      1800.0
      result <- stepSessionCommand adapter cmd st0
      result @?= StepControlAccepted
      admitSessionCommand cmd st0
        @?= SessionAdmitted cmd
              (PlanControlWrite binding (ControlTag (MigrationKey "lpf") 0) 1800.0)

  , testCase "commit-shaped success on control-write is a commit mismatch" $ do
      let graph   = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0     = applySessionCommit
                      (CommitVoiceStarted binding)
                      (initialSessionState graph)
          commit  = CommitVoiceStopped (VoiceKey "v0")
          adapter = constantAdapter (Right (RuntimeCommitted commit))
          cmd     = CmdControlWrite
                      (VoiceKey "v0")
                      (ControlTag (MigrationKey "lpf") 0)
                      1800.0
      result <- stepSessionCommand adapter cmd st0
      result @?= StepCommitMismatch SciControlPlanHasNoStateCommit
      ssVoices (applySessionCommit commit st0) @?= M.empty

  , testCase "hot-swap success returns commit-time ResolveRebuildResult" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          binding  = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          st0      = applySessionCommit
                       (CommitVoiceStarted binding)
                       (initialSessionState oldGraph)
          adapter  = constantAdapter
                       (Right (RuntimeCommitted
                                 (CommitGraphInstalled (SwapLabel "swap") newGraph)))
          cmd      = CmdHotSwap (SwapLabel "swap") newGraph
          expected = [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 (Just rebuild) -> do
          ssGraph st1 @?= newGraph
          ssVoices st1 @?= M.empty
          rrrDropped rebuild @?= expected
        other ->
          assertFailure ("expected StepCommitted with rebuild, got: " <> show other)

  , testCase "control-write ack on a non-control plan is a protocol bug" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          adapter = constantAdapter (Right RuntimeControlWriteAccepted)
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepAdapterProtocolBug msg ->
          assertBool ("expected PlanVoiceStart in protocol-bug message: " <> msg)
                     ("PlanVoiceStart" `isInfixOf` msg)
        other ->
          assertFailure ("expected StepAdapterProtocolBug, got: " <> show other)

  , testCase "PEVoiceOn flows through fromPatternEvent and stepSessionCommand" $ do
      let st0     = initialSessionState (patternTemplates droneVibrato)
          ev      = PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd     = fromPatternEvent ev
          binding = VoiceBinding (VoiceKey "v0") 17 (TemplateName "drone")
          adapter = constantAdapter
                      (Right (RuntimeCommitted (CommitVoiceStarted binding)))
      result <- stepSessionCommand adapter cmd st0
      case result of
        StepCommitted st1 Nothing ->
          ssVoices st1 @?= M.fromList [(VoiceKey "v0", binding)]
        other ->
          assertFailure ("expected StepCommitted via pattern event, got: " <> show other)
  ]

------------------------------------------------------------
-- Session Prep E: shared control-target resolver
--
-- The real RTGraph adapter will use the same symbolic
-- @(TemplateName, ControlTag)@ lookup as OSC dispatch. These tests
-- pin the pure resolver before adapter code starts depending on it.
------------------------------------------------------------

controlTargetTests :: TestTree
controlTargetTests = testGroup "Session Prep E: control target resolver"
  [ testCase "known target resolves to runtime node and control slot" $ do
      let tg      = patternTemplates droneVibrato
          target  = ControlTag (MigrationKey "lpf") 1
          lpfHits =
            [ rnIndex n
            | tpl <- tgTemplates tg
            , tplName tpl == "drone"
            , n <- rgNodes (tplGraph tpl)
            , rnMigrationKey n == Just (MigrationKey "lpf")
            ]
      case resolveControlTarget tg (TemplateName "drone") target of
        Right resolved -> do
          targetControlSlot resolved @?= 1
          assertBool
            ("expected lpf runtime target, got "
              <> show (targetNodeIndex resolved)
              <> " from candidates "
              <> show lpfHits)
            (targetNodeIndex resolved `elem` lpfHits)
        Left issue ->
          assertFailure ("expected resolved control target, got: " <> show issue)

  , testCase "missing template is reported structurally" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "missing")
        (ControlTag (MigrationKey "lpf") 0)
        @?= Left (CtiMissingTemplate (TemplateName "missing"))

  , testCase "missing node tag is reported structurally" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "no-such-tag") 0)
        @?= Left
              (CtiUnknownNodeTag
                 (TemplateName "drone")
                 (MigrationKey "no-such-tag"))

  , testCase "invalid control slot reports requested and available counts" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "lpf") 99)
        @?= Left
              (CtiInvalidControlSlot
                 (TemplateName "drone")
                 (MigrationKey "lpf")
                 99
                 2)

  , testCase "negative control slot reports requested and available counts" $ do
      let tg = patternTemplates droneVibrato
      resolveControlTarget
        tg
        (TemplateName "drone")
        (ControlTag (MigrationKey "lpf") (-1))
        @?= Left
              (CtiInvalidControlSlot
                 (TemplateName "drone")
                 (MigrationKey "lpf")
                 (-1)
                 2)
  ]

sessionRTGraphAdapterTests :: TestTree
sessionRTGraphAdapterTests = testGroup "Session Prep E: RTGraph session install"
  [ testCase "session install removes auto-spawn and leaves a reservable slot" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        result <- installSessionGraph rt tg defaultRTGraphAdapterOptions
        case result of
          Left issue ->
            assertFailure ("expected session graph install, got: " <> show issue)
          Right st -> do
            rtgasTemplateIds st
              @?= M.fromList [(TemplateName "drone", 0)]
            rtgasPrewarmCounts st
              @?= M.fromList [(TemplateName "drone", 1)]
            case M.lookup (TemplateName "drone") (rtgasAutoSpawnedSlots st) of
              Nothing ->
                assertFailure "expected recorded auto-spawn slot for drone"
              Just autoSlot -> do
                status <- c_rt_graph_instance_status rt (fromIntegral autoSlot)
                status @?= (-1)

            count <- c_rt_graph_instance_count rt
            statuses <- forM [0 .. count - 1] $ \slot ->
              c_rt_graph_instance_status rt slot
            assertBool
              ("expected no live logical voices after install, got statuses "
               <> show statuses)
              (all (== (-1)) statuses)

            slot <- c_rt_graph_realtime_reserve rt 0
            assertBool ("expected reserve to claim prewarmed slot, got "
                        <> show slot)
                       (slot >= 0)
            c_rt_graph_realtime_cancel rt slot

  , testCase "configured prewarm count is claimed through realtime reserve" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
          opts       = defaultRTGraphAdapterOptions
            { raoPerTemplatePolyphony =
                M.singleton (TemplateName "drone") 3
            }
      withRTGraph (totalNodes + 16) 64 $ \rt -> do
        result <- installSessionGraph rt tg opts
        case result of
          Left issue ->
            assertFailure ("expected session graph install, got: " <> show issue)
          Right st -> do
            rtgasPrewarmCounts st
              @?= M.fromList [(TemplateName "drone", 3)]
            slots <- forM [1 .. 3 :: Int] $ \_ ->
              c_rt_graph_realtime_reserve rt 0
            assertBool ("expected three successful reservations, got "
                        <> show slots)
                       (all (>= 0) slots)
            fourth <- c_rt_graph_realtime_reserve rt 0
            fourth @?= (-1)
            forM_ slots (c_rt_graph_realtime_cancel rt)

  , testCase "duplicate template names are rejected before install" $ do
      let base = patternTemplates arpeggioSendReturn
          duplicated = duplicateFirstTwoTemplates base
      withRTGraph 16 64 $ \rt -> do
        result <- installSessionGraph
                    rt
                    duplicated
                    defaultRTGraphAdapterOptions
        result @?= Left (SasiDuplicateTemplateName (TemplateName "dup"))
        templateCount <- c_rt_graph_template_count rt
        instanceCount <- c_rt_graph_instance_count rt
        templateCount @?= 1
        instanceCount @?= 1

  , testCase "adapter constructor installs graph and starts voice through adapter" $ do
      let tg         = patternTemplates droneVibrato
          totalNodes = totalTemplateNodes tg
      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        result <- newRTGraphAdapter rt tg defaultRTGraphAdapterOptions
        case result of
          Left issue ->
            assertFailure ("expected RTGraph adapter, got: " <> show issue)
          Right adapter -> do
            slot <- c_rt_graph_realtime_reserve rt 0
            assertBool ("expected constructor to prewarm reservable slot, got "
                        <> show slot)
                       (slot >= 0)
            c_rt_graph_realtime_cancel rt slot

            outcome <- sraRun adapter
              (PlanVoiceStart (TemplateName "drone") (VoiceKey "v1") [])
            case outcome of
              Right (RuntimeCommitted (CommitVoiceStarted binding)) -> do
                vbVoiceKey binding @?= VoiceKey "v1"
                vbTemplateName binding @?= TemplateName "drone"
                assertBool ("expected runtime slot, got " <> show (vbSlotId binding))
                           (vbSlotId binding >= 0)
              other ->
                assertFailure ("expected committed voice start, got: " <> show other)

  , testCase "step voice-start success commits reserved slot binding" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                  [(ControlTag (MigrationKey "lpf") 0, 1200.0)]
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        case result of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Just binding -> do
                vbTemplateName binding @?= TemplateName "drone"
                assertBool ("expected runtime slot, got "
                            <> show (vbSlotId binding))
                           (vbSlotId binding >= 0)
                c_rt_graph_process rt 1
                status <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                status @?= instanceStatusLive
              Nothing ->
                assertFailure "expected committed voice binding"
          other ->
            assertFailure ("expected StepCommitted, got: " <> show other)

  , testCase "fromPatternEvent voice-on drives real RTGraph adapter" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          ev  = PEVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "pv0")
                  [(ControlTag (MigrationKey "lpf") 0, 900.0)]
          cmd = fromPatternEvent ev
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        case result of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "pv0") (ssVoices st1) of
              Just binding -> do
                c_rt_graph_process rt 1
                status <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                status @?= instanceStatusLive
              Nothing ->
                assertFailure "expected committed PatternEvent voice binding"
          other ->
            assertFailure
              ("expected PatternEvent-backed RTGraph commit, got: " <> show other)

  , testCase "step voice-start with empty pool reports allocation failure" $ do
      let tg  = patternTemplates droneVibrato
          st0 = initialSessionState tg
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        held <- c_rt_graph_realtime_reserve rt 0
        assertBool ("expected setup reservation, got " <> show held) (held >= 0)
        result <- stepSessionCommand adapter cmd st0
        result @?= StepRuntimeFailed SriVoiceAllocationFailed
        c_rt_graph_realtime_cancel rt held

  , testCase "step voice-start invalid initial control cancels reservation" $ do
      let tg      = patternTemplates droneVibrato
          st0     = initialSessionState tg
          badTag  = ControlTag (MigrationKey "missing") 0
          cmd     = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                      [(badTag, 1.0)]
          issue   = CtiUnknownNodeTag
                      (TemplateName "drone")
                      (MigrationKey "missing")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        result <- stepSessionCommand adapter cmd st0
        result @?= StepRuntimeFailed (SriControlTargetRejected issue)
        -- defaultRTGraphAdapterOptions prewarms exactly one slot, so
        -- this reserve can only succeed if the failed start canceled
        -- its reservation back to Available.
        slot <- c_rt_graph_realtime_reserve rt 0
        assertBool ("expected canceled reservation to be reusable, got "
                    <> show slot)
                   (slot >= 0)
        c_rt_graph_realtime_cancel rt slot

  , testCase "step voice-stop queues release and clears session binding" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          stopCmd  = CmdVoiceOff (VoiceKey "v0")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                stopped <- stepSessionCommand adapter stopCmd st1
                case stopped of
                  StepCommitted st2 Nothing -> do
                    ssVoices st2 @?= M.empty
                    -- Voice-stop success means the release was queued;
                    -- this test intentionally does not assert post-drain
                    -- runtime slot status.
                    assertBool ("expected stopped binding slot, got "
                                <> show (vbSlotId binding))
                               (vbSlotId binding >= 0)
                  other ->
                    assertFailure
                      ("expected stopped voice commit, got: " <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step control-write to known target is accepted" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       1800.0
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            c_rt_graph_process rt 1
            written <- stepSessionCommand adapter writeCmd st1
            written @?= StepControlAccepted
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step control-write to unknown target is rejected" $ do
      let tg       = patternTemplates droneVibrato
          st0      = initialSessionState tg
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          badTag   = ControlTag (MigrationKey "missing") 0
          writeCmd = CmdControlWrite (VoiceKey "v0") badTag 1800.0
          issue    = CtiUnknownNodeTag
                       (TemplateName "drone")
                       (MigrationKey "missing")
      withInstalledAdapter tg defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            c_rt_graph_process rt 1
            written <- stepSessionCommand adapter writeCmd st1
            written @?= StepRuntimeFailed (SriControlTargetRejected issue)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step hot-swap of empty session installs new graph" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          st0      = initialSessionState oldGraph
          swapCmd  = CmdHotSwap (SwapLabel "to-stab") newGraph
          startCmd = CmdVoiceOn (TemplateName "stab") (VoiceKey "s0") []
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        -- The runtime side is exercised indirectly through the
        -- post-swap voice start; no direct FFI probe is needed here.
        swapped <- stepSessionCommand adapter swapCmd st0
        case swapped of
          StepCommitted st1 (Just rebuild) -> do
            ssGraph st1 @?= newGraph
            ssVoices st1 @?= M.empty
            rrrDropped rebuild @?= []
            started <- stepSessionCommand adapter startCmd st1
            case started of
              StepCommitted st2 Nothing ->
                assertBool
                  "expected stab voice after adapter metadata update"
                  (M.member (VoiceKey "s0") (ssVoices st2))
              other ->
                assertFailure ("expected post-swap voice start, got: " <> show other)
          other ->
            assertFailure ("expected empty-session hot-swap commit, got: "
                           <> show other)

  , testCase "step hot-swap install failure preserves structured setup issue" $ do
      let oldGraph = patternTemplates droneVibrato
          base     = patternTemplates arpeggioSendReturn
          newGraph = duplicateFirstTwoTemplates base
          st0     = initialSessionState oldGraph
          swapCmd = CmdHotSwap (SwapLabel "bad-graph") newGraph
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        swapped <- stepSessionCommand adapter swapCmd st0
        swapped @?= StepRuntimeFailed
          (SriHotSwapInstallFailed
            (SasiDuplicateTemplateName (TemplateName "dup")))

  , testCase "step hot-swap that drops active voices installs and reports drops" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          st0      = initialSessionState oldGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "drop-drone") newGraph
          expected = [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \_rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing -> do
            swapped <- stepSessionCommand adapter swapCmd st1
            case swapped of
              StepCommitted st2 (Just rebuild) -> do
                ssGraph st2 @?= newGraph
                ssVoices st2 @?= M.empty
                rrrDropped rebuild @?= expected
              other ->
                assertFailure ("expected dropping hot-swap commit, got: "
                               <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step unsupported preserving hot-swap is rejected" $ do
      let graph    = patternTemplates droneVibrato
          st0      = initialSessionState graph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "preserve-drone") graph
      withInstalledAdapter graph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                before <- c_rt_graph_instance_status
                            rt
                            (fromIntegral (vbSlotId binding))
                before @?= instanceStatusLive
                swapped <- stepSessionCommand adapter swapCmd st1
                swapped @?= StepRuntimeFailed SriHotSwapWouldPreserveVoices
                afterStatus <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding))
                afterStatus @?= instanceStatusLive
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step preserving hot-swap migrates supported active voice" $ do
      newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
      let oldGraph = patternTemplates hotSwapEdit
          st0      = initialSessionState oldGraph
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "lpf") 0, 1500.0)]
          swapCmd  = CmdHotSwap (SwapLabel "edit-cutoff") newGraph
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       3300.0
      withInstalledAdapter oldGraph defaultRTGraphAdapterOptions $ \rt adapter -> do
        started <- stepSessionCommand adapter startCmd st0
        case started of
          StepCommitted st1 Nothing ->
            case M.lookup (VoiceKey "v0") (ssVoices st1) of
              Nothing ->
                assertFailure "expected committed voice binding"
              Just binding -> do
                c_rt_graph_process rt 1
                beforeStatus <- c_rt_graph_instance_status
                                  rt
                                  (fromIntegral (vbSlotId binding))
                beforeStatus @?= instanceStatusLive
                beforeGeneration <- readSwapGeneration rt
                swapped <- stepSessionCommand adapter swapCmd st1
                case swapped of
                  StepCommitted st2 (Just rebuild) -> do
                    rrrDropped rebuild @?= []
                    ssGraph st2 @?= newGraph
                    M.lookup (VoiceKey "v0") (ssVoices st2) @?= Just binding
                    afterGeneration <- readSwapGeneration rt
                    assertBool
                      "expected preserving swap generation to advance"
                      (afterGeneration > beforeGeneration)
                    afterStatus <- c_rt_graph_instance_status
                                     rt
                                     (fromIntegral (vbSlotId binding))
                    afterStatus @?= instanceStatusLive
                    written <- stepSessionCommand adapter writeCmd st2
                    written @?= StepControlAccepted
                  other ->
                    assertFailure
                      ("expected preserving hot-swap commit, got: "
                       <> show other)
          other ->
            assertFailure ("expected start commit, got: " <> show other)

  , testCase "step preserving hot-swap migrates two supported active voices" $ do
      newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
      let oldGraph = patternTemplates hotSwapEdit
          opts     = defaultRTGraphAdapterOptions
            { raoDefaultPolyphony = 2
            }
          st0      = initialSessionState oldGraph
          v0       = VoiceKey "v0"
          v1       = VoiceKey "v1"
          start key cutoff =
            CmdVoiceOn (TemplateName "drone") key
              [(ControlTag (MigrationKey "lpf") 0, cutoff)]
          swapCmd  = CmdHotSwap (SwapLabel "edit-two") newGraph
      withInstalledAdapter oldGraph opts $ \rt adapter -> do
        started0 <- stepSessionCommand adapter (start v0 1200.0) st0
        case started0 of
          StepCommitted st1 Nothing -> do
            started1 <- stepSessionCommand adapter (start v1 1800.0) st1
            case started1 of
              StepCommitted st2 Nothing -> do
                case (M.lookup v0 (ssVoices st2), M.lookup v1 (ssVoices st2)) of
                  (Just binding0, Just binding1) -> do
                    c_rt_graph_process rt 1
                    before0 <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding0))
                    before1 <- c_rt_graph_instance_status
                                 rt
                                 (fromIntegral (vbSlotId binding1))
                    before0 @?= instanceStatusLive
                    before1 @?= instanceStatusLive
                    swapped <- stepSessionCommand adapter swapCmd st2
                    case swapped of
                      StepCommitted st3 (Just rebuild) -> do
                        rrrDropped rebuild @?= []
                        ssGraph st3 @?= newGraph
                        M.lookup v0 (ssVoices st3) @?= Just binding0
                        M.lookup v1 (ssVoices st3) @?= Just binding1
                        after0 <- c_rt_graph_instance_status
                                    rt
                                    (fromIntegral (vbSlotId binding0))
                        after1 <- c_rt_graph_instance_status
                                    rt
                                    (fromIntegral (vbSlotId binding1))
                        after0 @?= instanceStatusLive
                        after1 @?= instanceStatusLive
                      other ->
                        assertFailure
                          ("expected two-voice preserving hot-swap commit, got: "
                           <> show other)
                  other ->
                    assertFailure
                      ("expected two committed voice bindings, got: "
                       <> show other)
              other ->
                assertFailure
                  ("expected second start commit, got: " <> show other)
          other ->
            assertFailure ("expected first start commit, got: " <> show other)
  ]
  where
    totalTemplateNodes tg =
      sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

    withInstalledAdapter tg opts action =
      withRTGraph (totalTemplateNodes tg + 16) 64 $ \rt -> do
        result <- newRTGraphAdapter rt tg opts
        case result of
          Left issue ->
            assertFailure ("expected RTGraph adapter, got: " <> show issue)
          Right adapter ->
            action rt adapter

------------------------------------------------------------
-- Session Prep F: single-threaded runtime owner
------------------------------------------------------------

sessionOwnerTests :: TestTree
sessionOwnerTests = testGroup "Session Prep F: runtime owner"
  [ testCase "owner construction initializes state and status" $ do
      let tg = patternTemplates droneVibrato
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (st, status) -> do
          ssGraph st @?= tg
          ssVoices st @?= M.empty
          status @?= SessionOwnerReady

  , testCase "owner construction surfaces setup failure" $ do
      let duplicated = duplicateFirstTwoTemplates
                         (patternTemplates arpeggioSendReturn)
      result <- withSessionOwner
                  duplicated
                  defaultSessionOwnerOptions
                  (\_ -> pure ())
      result @?= Left (SasiDuplicateTemplateName (TemplateName "dup"))

  , testCase "owner voice-start mutates internal state" $ do
      let tg  = patternTemplates droneVibrato
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        stepped <- stepSessionOwner owner cmd
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (stepped, st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing), st, status) -> do
          assertBool
            "expected owner state to contain started voice"
            (M.member (VoiceKey "v0") (ssVoices st))
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner voice-start commit, got: " <> show other)

  , testCase "owner voice-stop removes internal binding" $ do
      let tg       = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          stopCmd  = CmdVoiceOff (VoiceKey "v0")
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        stopped <- stepSessionOwner owner stopCmd
        st <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (started, stopped, st, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               SessionOwnerStep (StepCommitted _ Nothing), st, status) -> do
          ssVoices st @?= M.empty
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner voice-stop commit, got: " <> show other)

  , testCase "owner control-write accepts without state mutation" $ do
      let tg       = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       700.0
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        before <- sessionOwnerState owner
        written <- stepSessionOwner owner writeCmd
        afterState <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (started, before, written, afterState, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing), before,
               SessionOwnerStep StepControlAccepted, afterState, status) -> do
          afterState @?= before
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner control-write accept, got: " <> show other)

  , testCase "owner duplicate hot-swap diverges and blocks later commands" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          issue    = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          swapCmd  = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $ \owner -> do
        diverged <- stepSessionOwner owner swapCmd
        status <- sessionOwnerStatus owner
        blocked <- stepSessionOwner owner laterCmd
        pure (diverged, status, blocked)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (diverged, status, blocked) -> do
          diverged @?= SessionOwnerDivergedNow
            (StepRuntimeFailed (SriHotSwapInstallFailed issue))
            divergedReason
          status @?= SessionOwnerDiverged divergedReason
          -- SessionOwnerBlocked is produced only by the
          -- stepSessionOwner early-exit branch, before adapter
          -- invocation.
          blocked @?= SessionOwnerBlocked divergedReason

  , testCase "owner empty-session hot-swap updates graph and starts new voice" $ do
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          swapCmd  = CmdHotSwap (SwapLabel "to-stab") newGraph
          startCmd = CmdVoiceOn (TemplateName "stab") (VoiceKey "s0") []
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $ \owner -> do
        swapped <- stepSessionOwner owner swapCmd
        afterSwap <- sessionOwnerState owner
        started <- stepSessionOwner owner startCmd
        afterStart <- sessionOwnerState owner
        status <- sessionOwnerStatus owner
        pure (swapped, afterSwap, started, afterStart, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ (Just rebuild)),
               afterSwap,
               SessionOwnerStep (StepCommitted _ Nothing),
               afterStart,
               status) -> do
          ssGraph afterSwap @?= newGraph
          ssVoices afterSwap @?= M.empty
          rrrDropped rebuild @?= []
          ssGraph afterStart @?= newGraph
          assertBool
            "expected owner state to contain started stab voice"
            (M.member (VoiceKey "s0") (ssVoices afterStart))
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected owner hot-swap then voice-start, got: "
                         <> show other)

  , testCase "owner unsupported preserving hot-swap rejection is non-terminal" $ do
      let graph    = patternTemplates droneVibrato
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          swapCmd  = CmdHotSwap (SwapLabel "preserve") graph
      result <- withSessionOwner graph defaultSessionOwnerOptions $ \owner -> do
        started <- stepSessionOwner owner startCmd
        rejected <- stepSessionOwner owner swapCmd
        status <- sessionOwnerStatus owner
        pure (started, rejected, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               SessionOwnerStep (StepRuntimeFailed SriHotSwapWouldPreserveVoices),
               status) ->
          status @?= SessionOwnerReady
        Right other ->
          assertFailure
            ("expected non-terminal preserving hot-swap rejection, got: "
             <> show other)

  , testCase "owner admission rejection is non-terminal" $ do
      let tg  = patternTemplates droneVibrato
          cmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
      result <- withSessionOwner tg defaultSessionOwnerOptions $ \owner -> do
        rejected <- stepSessionOwner owner cmd
        status <- sessionOwnerStatus owner
        pure (rejected, status)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepRejected (SiUnknownTemplate (TemplateName "missing"))),
               status) ->
          status @?= SessionOwnerReady
        Right other ->
          assertFailure ("expected non-terminal admission rejection, got: "
                         <> show other)
  ]

duplicateFirstTwoTemplates :: TemplateGraph -> TemplateGraph
duplicateFirstTwoTemplates base =
  case tgTemplates base of
    (a : b : rest) ->
      base { tgTemplates =
               a { tplName = "dup" }
             : b { tplName = "dup" }
             : rest
           }
    _ ->
      error "expected at least two templates for duplicate-name test"

------------------------------------------------------------
-- Session Prep G: producer queue and owner drain
------------------------------------------------------------

sessionQueueTests :: TestTree
sessionQueueTests = testGroup "Session Prep G: producer queue"
  [ testCase "default options construct a positive bounded queue" $ do
      sqoCapacity defaultSessionQueueOptions @?= 128
      case newSessionCommandQueue defaultSessionQueueOptions of
        Left issue ->
          assertFailure ("expected default queue, got: " <> show issue)
        Right queue ->
          queue @?= queue

  , testCase "invalid queue capacities reject at construction" $ do
      newSessionCommandQueue (SessionQueueOptions 0)
        @?= Left (SqsiInvalidCapacity 0)
      newSessionCommandQueue (SessionQueueOptions (-1))
        @?= Left (SqsiInvalidCapacity (-1))

  , testCase "enqueue assigns per-queue sequence and rejects when full" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOff (VoiceKey "v0")
          cmd2 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
          (queue1, enq0) = enqueueSessionCommand pat cmd0 queue0
          (queue2, enq1) = enqueueSessionCommand osc cmd1 queue1
          (queue3, enq2) = enqueueSessionCommand pat cmd2 queue2
      case (enq0, enq1) of
        (SessionEnqueued q0, SessionEnqueued q1) -> do
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= pat
          qscProducer q1 @?= osc
        other ->
          assertFailure ("expected two accepted enqueues, got: " <> show other)
      enq2 @?= SessionEnqueueRejected pat cmd2 (SeiQueueFull 2)
      queue3 @?= queue2

  , testCase "rejected enqueue does not consume a sequence number" $ do
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let producer = testProducer ProducerTest "test"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v0") []
          rejectedCmd = CmdVoiceOn (TemplateName "missing") (VoiceKey "v1") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "v2") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      qscSequence queued0 @?= CommandSequence 0
      let (queueFull, rejected) =
            enqueueSessionCommand producer rejectedCmd queue1
      rejected @?=
        SessionEnqueueRejected producer rejectedCmd (SeiQueueFull 1)
      queueFull @?= queue1
      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (`drainSessionCommandQueue` queueFull)
      queue2 <- case drained of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (queue2, drain) -> do
          map sdiQueued (sdrItems drain) @?= [queued0]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue2
      (_queue3, queued1) <- enqueueOrFail producer cmd1 queue2
      qscSequence queued1 @?= CommandSequence 1

  , testCase "drain preserves FIFO order and producer identity" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let pat = testProducer ProducerPattern "pattern"
          osc = testProducer ProducerOSC "osc"
          cmd0 = CmdVoiceOn (TemplateName "missing") (VoiceKey "p0") []
          cmd1 = CmdVoiceOn (TemplateName "missing") (VoiceKey "o0") []
      (queue1, queued0) <- enqueueOrFail pat cmd0 queue0
      (queue2, queued1) <- enqueueOrFail osc cmd1 queue1
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  (`drainSessionCommandQueue` queue2)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (_queue3, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          map sdiQueued (sdrItems drain) @?= [queued0, queued1]
          map sdiResult (sdrItems drain)
            @?= [ SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                , SessionOwnerStep
                    (StepRejected (SiUnknownTemplate (TemplateName "missing")))
                ]

  , testCase "drain control-write accepts without owner state mutation" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let producer = testProducer ProducerUI "ui"
          startCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd = CmdControlWrite
                       (VoiceKey "v0")
                       (ControlTag (MigrationKey "lpf") 0)
                       900.0
      (queue1, queued) <- enqueueOrFail producer writeCmd queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    started <- stepSessionOwner owner startCmd
                    before <- sessionOwnerState owner
                    drained <- drainSessionCommandQueue owner queue1
                    afterState <- sessionOwnerState owner
                    pure (started, before, drained, afterState)
      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               before, (_queue2, drain), afterState) -> do
          afterState @?= before
          sdrItems drain @?=
            [SessionDrainItem queued (SessionOwnerStep StepControlAccepted)]
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
        Right other ->
          assertFailure ("expected started owner and accepted control write, got: "
                         <> show other)

  , testCase "divergence stops drain and leaves remaining command queued" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerPattern "pattern"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          later = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      (queue1, badQueued) <- enqueueOrFail producer badSwap queue0
      (queue2, laterQueued) <- enqueueOrFail producer later queue1
      firstDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner queue2
      (remainingQueue, firstResult) <- case firstDrain of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right value ->
          pure value
      sdrItems firstResult @?=
        [ SessionDrainItem
            badQueued
            (SessionOwnerDivergedNow
              (StepRuntimeFailed (SriHotSwapInstallFailed issue))
              divergedReason)
        ]
      sdrRemaining firstResult @?= 1
      sdrStopped firstResult @?= Just divergedReason

      secondDrain <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> drainSessionCommandQueue owner remainingQueue
      case secondDrain of
        Left setupIssue ->
          assertFailure ("expected second session owner, got: " <> show setupIssue)
        Right (_emptyQueue, secondResult) -> do
          map sdiQueued (sdrItems secondResult) @?= [laterQueued]
          case map sdiResult (sdrItems secondResult) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected remaining voice-start commit, got: "
                             <> show other)
          sdrRemaining secondResult @?= 0
          sdrStopped secondResult @?= Nothing

  , testCase "already-diverged owner blocks first queued command and stops" $ do
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let oldGraph = patternTemplates droneVibrato
          badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerTest "test"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed issue
          badSwap = CmdHotSwap (SwapLabel "bad-graph") badGraph
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      (queue1, queued0) <- enqueueOrFail producer cmd0 queue0
      (queue2, _queued1) <- enqueueOrFail producer cmd1 queue1
      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          diverged <- stepSessionOwner owner badSwap
          drained <- drainSessionCommandQueue owner queue2
          pure (diverged, drained)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (SessionOwnerDivergedNow
                 (StepRuntimeFailed (SriHotSwapInstallFailed _))
                 _,
               (_remainingQueue, drain)) -> do
          sdrItems drain @?=
            [SessionDrainItem queued0 (SessionOwnerBlocked divergedReason)]
          sdrRemaining drain @?= 1
          sdrStopped drain @?= Just divergedReason
        Right other ->
          assertFailure ("expected diverged owner then blocked drain, got: "
                         <> show other)
  ]

testProducer :: ProducerKind -> String -> ProducerId
testProducer kind name =
  ProducerId kind (T.pack name)

queueOrFail :: SessionQueueOptions -> IO SessionCommandQueue
queueOrFail opts =
  case newSessionCommandQueue opts of
    Left issue ->
      assertFailure ("expected queue, got: " <> show issue)
    Right queue ->
      pure queue

enqueueOrFail
  :: ProducerId
  -> SessionCommand
  -> SessionCommandQueue
  -> IO (SessionCommandQueue, QueuedSessionCommand)
enqueueOrFail producer cmd queue =
  case enqueueSessionCommand producer cmd queue of
    (queue', SessionEnqueued queued) ->
      pure (queue', queued)
    (_queue', other) ->
      assertFailure ("expected enqueue success, got: " <> show other)

------------------------------------------------------------
-- Session producer arbitration policy
------------------------------------------------------------

sessionArbitrationTests :: TestTree
sessionArbitrationTests =
  testGroup "Session producer arbitration policy"
  [ testCase "FifoOnly accepts same-target writes from multiple producers" $ do
      let patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          writeCmd = CmdControlWrite (VoiceKey "v0") midiLevelTag 0.75
      arbitrateSessionCommand FifoOnly patternProducer writeCmd
        @?= ArbitrationAllowed
      arbitrateSessionCommand FifoOnly oscProducer writeCmd
        @?= ArbitrationAllowed

  , testCase "priority policy accepts winner and rejects loser" $ do
      let currentOwner = testProducer ProducerOSC "osc"
          winner       = testProducer ProducerMIDI "midi"
          loser        = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
          owners =
            setControlOwner target currentOwner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
          expectedIssue = ArbitrationIssue
            { aiProducer  = loser
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan currentOwner
            , aiRetryable = False
            }
      arbitrateSessionCommand policy winner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy loser command
        @?= ArbitrationRejected expectedIssue

  , testCase "priority policy allows equal-priority producers" $ do
      let owner     = testProducer ProducerMIDI "midi-a"
          peer      = testProducer ProducerMIDI "midi-b"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
          owners =
            setControlOwner target owner emptyControlOwnerTable
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              owners
      arbitrateSessionCommand policy owner command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy peer command
        @?= ArbitrationAllowed

  , testCase "priority policy allows unowned targets" $ do
      let producer = testProducer ProducerPattern "pattern"
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
          policy =
            ProducerPriority
              [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
              emptyControlOwnerTable
      arbitrateSessionCommand policy producer command
        @?= ArbitrationAllowed

  , testCase "target claim blocks only the claimed control target" $ do
      let claimant  = testProducer ProducerUI "ui"
          blocked   = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          otherTarget =
            ControlArbitrationTarget (VoiceKey "v0") midiFreqTag
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") midiFreqTag 440.0
          claims =
            claimControlTarget target claimant emptyTargetClaimTable
          policy =
            TargetClaim claims
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      arbitrateSessionCommand policy claimant command
        @?= ArbitrationAllowed
      arbitrateSessionCommand policy blocked command
        @?= ArbitrationRejected expectedIssue
      arbitrateSessionCommand policy blocked otherCommand
        @?= ArbitrationAllowed
      sessionCommandControlTarget otherCommand @?= Just otherTarget

  , testCase "lifecycle and hot-swap commands bypass v1 control arbitration" $ do
      let claimant = testProducer ProducerUI "ui"
          producer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          policy =
            TargetClaim
              (claimControlTarget target claimant emptyTargetClaimTable)
          commands =
            [ CmdVoiceOn (TemplateName "voice") (VoiceKey "v0") []
            , CmdVoiceOff (VoiceKey "v0")
            , CmdHotSwap (SwapLabel "refresh") (patternTemplates droneVibrato)
            ]
      map sessionCommandControlTarget commands
        @?= replicate (length commands) Nothing
      map (arbitrateSessionCommand policy producer) commands
        @?= replicate (length commands) ArbitrationAllowed
  ]

sessionArbitrationGatewayTests :: TestTree
sessionArbitrationGatewayTests =
  testGroup "Session producer arbitration gateway"
  [ testCase "default FifoOnly gateway preserves fan-in enqueue behavior" $ do
      let graph = patternTemplates droneVibrato
          patternProducer = testProducer ProducerPattern "pattern"
          oscProducer     = testProducer ProducerOSC "osc"
          command0 =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.25
          command1 =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway
            defaultSessionArbitrationGatewayOptions
            $ \gateway -> do
                enq0 <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command0 host
                enq1 <- enqueueArbitratedSessionFanInCommand
                          gateway oscProducer command1 host
                policy <- readSessionArbitrationGatewayPolicy gateway
                pure (enq0, enq1, policy)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, policy) -> do
          q0 <- gatewayQueuedOrFail enq0
          q1 <- gatewayQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map qscProducer [q0, q1] @?= [patternProducer, oscProducer]
          policy @?= FifoOnly

  , testCase "priority gateway rejects before fan-in and updates owner on accept" $ do
      let graph = patternTemplates droneVibrato
          oscProducer     = testProducer ProducerOSC "osc"
          midiProducer    = testProducer ProducerMIDI "midi"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
          opts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway opts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer command host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway patternProducer command host
            snapshotAfterReject <- readSessionFanInHost host
            enq1 <- enqueueArbitratedSessionFanInCommand
                      gateway midiProducer command host
            policyAfterMidi <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterMidi <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , snapshotAfterReject
              , enq1
              , policyAfterMidi
              , snapshotAfterMidi
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , snapshotAfterReject
          , enq1
          , policyAfterMidi
          , snapshotAfterMidi
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            q1 <- gatewayQueuedOrFail enq1
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscProducer q0 @?= oscProducer
            qscProducer q1 @?= midiProducer
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshotAfterReject @?= 1
            sfisQueueDepth snapshotAfterMidi @?= 2
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterMidi target midiProducer

  , testCase "priority gateway keeps owner unchanged when fan-in rejects" $ do
      let graph = patternTemplates droneVibrato
          fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          oscProducer  = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          oscCommand =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.25
          midiCommand =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.75
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                ProducerPriority
                  [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                  emptyControlOwnerTable
            }
      result <-
        withSessionFanInHost graph fanInOpts $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            enq0 <- enqueueArbitratedSessionFanInCommand
                      gateway oscProducer oscCommand host
            policyAfterOsc <- readSessionArbitrationGatewayPolicy gateway
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway midiProducer midiCommand host
            policyAfterReject <- readSessionArbitrationGatewayPolicy gateway
            snapshotAfterReject <- readSessionFanInHost host
            pure
              ( enq0
              , policyAfterOsc
              , rejected
              , policyAfterReject
              , snapshotAfterReject
              )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right
          ( enq0
          , policyAfterOsc
          , rejected
          , policyAfterReject
          , snapshotAfterReject
          ) -> do
            q0 <- gatewayQueuedOrFail enq0
            qscProducer q0 @?= oscProducer
            case rejected of
              SagArbitrationRejected issue ->
                assertFailure ("expected fan-in rejection, got: "
                               <> show issue)
              SagEnqueueAttempted fanInResult -> do
                sfierResult fanInResult
                  @?= SessionEnqueueRejected
                        midiProducer
                        midiCommand
                        (SeiQueueFull 1)
                sfierQueueDepth fanInResult @?= 1
            sfisQueueDepth snapshotAfterReject @?= 1
            assertPriorityOwner policyAfterOsc target oscProducer
            assertPriorityOwner policyAfterReject target oscProducer

  , testCase "target-claim gateway rejects only the claimed target before fan-in" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") midiFreqTag 440.0
          gatewayOpts = defaultSessionArbitrationGatewayOptions
            { sagoInitialPolicy =
                TargetClaim
                  (claimControlTarget target claimant emptyTargetClaimTable)
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      result <-
        withSessionFanInHost graph defaultSessionFanInOptions $ \host ->
          withSessionArbitrationGateway gatewayOpts $ \gateway -> do
            claimantEnq <- enqueueArbitratedSessionFanInCommand
                             gateway claimant claimedCommand host
            rejected <- enqueueArbitratedSessionFanInCommand
                          gateway blocked claimedCommand host
            otherEnq <- enqueueArbitratedSessionFanInCommand
                          gateway blocked otherCommand host
            snapshot <- readSessionFanInHost host
            pure (claimantEnq, rejected, otherEnq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (claimantEnq, rejected, otherEnq, snapshot) -> do
          q0 <- gatewayQueuedOrFail claimantEnq
          q1 <- gatewayQueuedOrFail otherEnq
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          qscProducer q0 @?= claimant
          qscProducer q1 @?= blocked
          qscCommand q0 @?= claimedCommand
          qscCommand q1 @?= otherCommand
          rejected @?= SagArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 2
  ]

------------------------------------------------------------
-- Session Prep H: Pattern producer bridge
------------------------------------------------------------

sessionPatternProducerTests :: TestTree
sessionPatternProducerTests = testGroup "Session Prep H: Pattern producer"
  [ testCase "default options construct Pattern producer identity" $ do
      assertBool
        "expected positive default block size"
        (ppoBlockFrames defaultPatternProducerOptions > 0)
      producer <- patternProducerOrFail defaultPatternProducerOptions
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
          result = peoResult outcome
      perNextStart result @?= SamplePos (ppoBlockFrames defaultPatternProducerOptions)
      case perItems result of
        [item] ->
          case peiResult item of
            SessionEnqueued queued ->
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern")
            other ->
              assertFailure ("expected default producer enqueue, got: "
                             <> show other)
        other ->
          assertFailure ("expected one default producer item, got: "
                         <> show other)

  , testCase "invalid block sizes reject at construction" $ do
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = 0 })
        @?= Left (PpiInvalidBlockFrames 0)
      newPatternProducerState
        (defaultPatternProducerOptions { ppoBlockFrames = (-8) })
        @?= Left (PpiInvalidBlockFrames (-8))

  , testCase "backlog predicate tracks queue-pressure retry state" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      partialRetryQueue <- queueOrFail (SessionQueueOptions 1)
      finalRetryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 =
            enqueuePatternBlock pat (peoState outcome1) partialRetryQueue
          outcome3 =
            enqueuePatternBlock pat (peoState outcome2) finalRetryQueue
      assertBool
        "new Pattern producer should start without backlog"
        (not (isBacklogged producer))
      assertBool
        "partial enqueue rejection should leave producer backlogged"
        (isBacklogged (peoState outcome1))
      assertBool
        "partial retry should keep producer backlogged"
        (isBacklogged (peoState outcome2))
      assertBool
        "successful final retry should clear producer backlog"
        (not (isBacklogged (peoState outcome3)))
      perBacklogged (peoResult outcome1) @?= 2
      perBacklogged (peoResult outcome2) @?= 1
      perBacklogged (peoResult outcome3) @?= 0

  , testCase "empty block advances cursor and enqueues nothing" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 16 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let emptyPattern = droneVibrato
            { patternEvents = staticEvents [] }
          outcome = enqueuePatternBlock emptyPattern producer queue0
          result = peoResult outcome
      perItems result @?= []
      perBacklogged result @?= 0
      perNextStart result @?= SamplePos 16

  , testCase "first droneVibrato block enqueues expected VoiceOn command" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "composer"
          , ppoBlockFrames  = 64
          })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      case perItems (peoResult outcome) of
        [item] -> do
          peiSamplePos item @?= fst expectedEvent
          peiEvent item @?= snd expectedEvent
          peiCommand item @?= fromPatternEvent (snd expectedEvent)
          case peiResult item of
            SessionEnqueued queued -> do
              qscSequence queued @?= CommandSequence 0
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "composer")
            other ->
              assertFailure ("expected queued VoiceOn, got: " <> show other)
        other ->
          assertFailure ("expected one droneVibrato item, got: " <> show other)

  , testCase "same-sample Pattern events preserve emit order" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 1 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let expected = take 2 arpeggioSendReturnEvents
          outcome = enqueuePatternBlock arpeggioSendReturn producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd expected
      map peiSamplePos items @?= map fst expected
      mapMaybe itemSequence items @?= [CommandSequence 0, CommandSequence 1]

  , testCase "every PatternEvent constructor maps through fromPatternEvent" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 8)
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 1
              , PEControlWrite
                  (VoiceKey "v0")
                  (ControlTag (MigrationKey "lpf") 0)
                  1200.0
              )
            , ( SamplePos 2
              , PEVoiceOff (VoiceKey "v0")
              )
            , ( SamplePos 3
              , PEHotSwap
                  (SwapLabel "edit")
                  (patternTemplates polyphonicStab)
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome = enqueuePatternBlock pat producer queue0
          items = perItems (peoResult outcome)
      map peiEvent items @?= map snd events
      map peiCommand items @?= map (fromPatternEvent . snd) events
      perBacklogged (peoResult outcome) @?= 0

  , testCase "full queue stops at first rejection and retains tail backlog" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      let events = missingVoiceEvents 4
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      map peiEvent (perItems result1) @?= map snd (take 2 events)
      perBacklogged result1 @?= 3
      case map peiResult (perItems result1) of
        [SessionEnqueued _, SessionEnqueueRejected {}] ->
          pure ()
        other ->
          assertFailure ("expected enqueue then rejection, got: "
                         <> show other)

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= map snd (drop 1 events)

  , testCase "rejected backlog does not consume queue sequence numbers" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let events = missingVoiceEvents 3
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          result1 = peoResult outcome1
      mapMaybe itemSequence (perItems result1)
        @?= [CommandSequence 0, CommandSequence 1]
      perBacklogged result1 @?= 1

      drained <- withSessionOwner
                   (patternTemplates droneVibrato)
                   defaultSessionOwnerOptions
                   (\owner -> drainSessionCommandQueue owner (peoQueue outcome1))
      drainedQueue <- case drained of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (queue1, drain) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          pure queue1

      let outcome2 = enqueuePatternBlock pat (peoState outcome1) drainedQueue
          result2 = peoResult outcome2
      perNextStart result2 @?= perNextStart result1
      perBacklogged result2 @?= 0
      map peiEvent (perItems result2) @?= [snd (events !! 2)]
      mapMaybe itemSequence (perItems result2) @?= [CommandSequence 2]

  , testCase "retry call does not generate a fresh range after backlog drains" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 2)
      retryQueue <- queueOrFail (SessionQueueOptions 8)
      nextQueue <- queueOrFail (SessionQueueOptions 8)
      let events =
            missingVoiceEventsAt [0, 1, 2, 8]
          pat = droneVibrato { patternEvents = staticEvents events }
          outcome1 = enqueuePatternBlock pat producer queue0
          outcome2 = enqueuePatternBlock pat (peoState outcome1) retryQueue
          outcome3 = enqueuePatternBlock pat (peoState outcome2) nextQueue
      perBacklogged (peoResult outcome1) @?= 1
      perNextStart (peoResult outcome2)
        @?= perNextStart (peoResult outcome1)
      map peiSamplePos (perItems (peoResult outcome2))
        @?= [SamplePos 2]
      perBacklogged (peoResult outcome2) @?= 0
      perNextStart (peoResult outcome3) @?= SamplePos 16
      map peiSamplePos (perItems (peoResult outcome3))
        @?= [SamplePos 8]

  , testCase "producer enqueue drains through owner and commits a real voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let outcome = enqueuePatternBlock droneVibrato producer queue0
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    drained <- drainSessionCommandQueue owner (peoQueue outcome)
                    st <- sessionOwnerState owner
                    pure (drained, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right ((_queue1, drain), st) -> do
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          case map sdiResult (sdrItems drain) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected committed Pattern producer voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after drain, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "arbitrated service Pattern enqueue defaults to FIFO" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 64
          })
      expectedEvent <- case listToMaybe droneVibratoEvents of
        Just event ->
          pure event
        Nothing ->
          assertFailure "expected droneVibratoEvents to contain a first event"
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock
                           droneVibrato
                           producer
                           service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just drained, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "arbitrated Pattern producer should not leave backlog after one clean block"
            (not (isBacklogged (paeoState outcome)))
          paerBacklogged result' @?= 0
          paerNextStart result' @?= SamplePos 64
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst expectedEvent
              paeiEvent item @?= snd expectedEvent
              paeiCommand item @?= fromPatternEvent (snd expectedEvent)
              queued <- gatewayQueuedOrFail (paeiResult item)
              qscProducer queued
                @?= ProducerId ProducerPattern (T.pack "pattern-arb")
              qscCommand queued @?= paeiCommand item
              map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
              case map sdiResult (sdrItems (sfidrDrain drained)) of
                [SessionOwnerStep (StepCommitted _ Nothing)] ->
                  pure ()
                other ->
                  assertFailure
                    ("expected arbitrated Pattern voice-on to commit, got: "
                     <> show other)
            other ->
              assertFailure ("expected one arbitrated Pattern item, got: "
                             <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected Pattern voice after arbitrated service drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_outcome, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated Pattern service drain"

  , testCase "arbitrated service Pattern rejection reports service issue" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let event =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") midiLevelTag 0.75
            )
          pat = droneVibrato { patternEvents = staticEvents [event] }
          command = fromPatternEvent (snd event)
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Nothing, snapshot) -> do
          let result' = paeoResult outcome
          assertBool
            "policy-rejected Pattern event should remain backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 1
          paerNextStart result' @?= SamplePos 8
          case paerItems result' of
            [item] -> do
              paeiSamplePos item @?= fst event
              paeiEvent item @?= snd event
              paeiCommand item @?= command
              paeiResult item @?= SagArbitrationRejected expectedIssue
            other ->
              assertFailure
                ("expected one rejected arbitrated Pattern item, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service Pattern halts on mid-block rejection" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions
          { ppoProducerName = T.pack "pattern-arb"
          , ppoBlockFrames  = 8
          })
      let firstTarget = ControlTag (MigrationKey "lpf") 1
          claimedTarget = midiLevelTag
          firstEvent =
            ( SamplePos 0
            , PEControlWrite (VoiceKey "v0") firstTarget 4.0
            )
          rejectedEvent =
            ( SamplePos 1
            , PEControlWrite (VoiceKey "v0") claimedTarget 0.75
            )
          tailEvent =
            (SamplePos 2, PEVoiceOff (VoiceKey "v0"))
          events =
            [firstEvent, rejectedEvent, tailEvent]
          pat = droneVibrato { patternEvents = staticEvents events }
          producerId = ProducerId ProducerPattern (T.pack "pattern-arb")
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget (VoiceKey "v0") claimedTarget
          firstCommand = fromPatternEvent (snd firstEvent)
          rejectedCommand = fromPatternEvent (snd rejectedEvent)
          tailCommand = fromPatternEvent (snd tailEvent)
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producerId
            , aiCommand   = rejectedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              outcome <- enqueueArbitratedPatternBlock pat producer service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              mSecondDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (outcome, mIssue, mFirstDrain, mSecondDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (outcome, Just reported, Just firstDrain, Nothing, snapshot) -> do
          let result' = paeoResult outcome
              items = paerItems result'
          assertBool
            "mid-block rejection should leave Pattern producer backlogged"
            (isBacklogged (paeoState outcome))
          paerBacklogged result' @?= 2
          paerNextStart result' @?= SamplePos 8
          map paeiCommand items @?= [firstCommand, rejectedCommand]
          assertBool
            "tail command should not be attempted after mid-block rejection"
            (tailCommand `notElem` map paeiCommand items)
          case items of
            [acceptedItem, rejectedItem] -> do
              queued <- gatewayQueuedOrFail (paeiResult acceptedItem)
              qscProducer queued @?= producerId
              qscCommand queued @?= firstCommand
              paeiResult rejectedItem
                @?= SagArbitrationRejected expectedIssue
              map sdiQueued (sdrItems (sfidrDrain firstDrain))
                @?= [queued]
              length (sdrItems (sfidrDrain firstDrain)) @?= 1
            other ->
              assertFailure
                ("expected accepted then rejected Pattern items, got: "
                 <> show other)
          reported @?= SfsiiArbitrationRejected expectedIssue
          sfisQueueDepth snapshot @?= 0
        Right (_outcome, Nothing, _mFirstDrain, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for Pattern arbitration rejection issue"
        Right (_outcome, Just _reported, Nothing, _mSecondDrain, _snapshot) ->
          assertFailure "timed out waiting for admitted Pattern drain"
        Right (_outcome, Just _reported, Just _firstDrain, Just extraDrain, _snapshot) ->
          assertFailure
            ("Pattern mid-block rejection unexpectedly produced extra drain: "
             <> show extraDrain)
  ]

------------------------------------------------------------
-- Session Prep I: scripted Pattern runner
------------------------------------------------------------

sessionRunnerTests :: TestTree
sessionRunnerTests = testGroup "Session Prep I: scripted runner"
  [ testCase "one runner step enqueues and commits a Pattern voice" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 64 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step <- stepPatternSession droneVibrato producer queue0 owner
                    st <- sessionOwnerState owner
                    pure (step, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step, st) -> do
          assertBool
            "runner should leave the producer without backlog after one block"
            (not (isBacklogged (prsState step)))
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          perBacklogged (prsEnqueue step) @?= 0
          case map sdiResult (sdrItems (prsDrain step)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure ("expected one committed runner voice, got: "
                             <> show other)
          assertBool
            ("expected v0 voice after runner step, got " <> show (ssVoices st))
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "backlog retries drain across repeated runner steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let voiceOn k =
            PEVoiceOn (TemplateName "stab") (VoiceKey k)
              [ (ControlTag (MigrationKey "lpf")      0, 800.0)
              , (ControlTag (MigrationKey "envelope") 0, 1.0)
              ]
          events =
            [ (SamplePos 0, voiceOn "s0")
            , (SamplePos 1, voiceOn "s1")
            , (SamplePos 2, voiceOn "s2")
            ]
          pat = polyphonicStab { patternEvents = staticEvents events }
      let ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
      result <- withSessionOwner
                  (patternTemplates polyphonicStab)
                  ownerOpts
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    step3 <- stepPatternSession pat (prsState step2) (prsQueue step2) owner
                    st <- sessionOwnerState owner
                    pure (step1, step2, step3, st)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, step3, st) -> do
          assertBool
            "step 1 should leave producer backlogged after queue saturation"
            (isBacklogged (prsState step1))
          assertBool
            "step 2 should still be backlogged after retrying one event"
            (isBacklogged (prsState step2))
          assertBool
            "step 3 should clear producer backlog"
            (not (isBacklogged (prsState step3)))
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          sdrStopped (prsDrain step1) @?= Nothing
          sdrStopped (prsDrain step2) @?= Nothing
          sdrStopped (prsDrain step3) @?= Nothing
          assertBool
            ("expected s0, s1, s2 voices after runner backlog drain, got "
              <> show (ssVoices st))
            (all (\k -> M.member (VoiceKey k) (ssVoices st)) ["s0","s1","s2"])

  , testCase "owner divergence stops the runner drain and blocks later steps" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 4)
      let badGraph = duplicateFirstTwoTemplates
                       (patternTemplates arpeggioSendReturn)
          divergedReason = SodHotSwapInstallFailed
                             (SasiDuplicateTemplateName (TemplateName "dup"))
          events =
            [ (SamplePos 0, PEHotSwap (SwapLabel "bad-graph") badGraph)
            , (SamplePos 1, PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    status <- sessionOwnerStatus owner
                    pure (step1, step2, status)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2, status) -> do
          sdrStopped (prsDrain step1) @?= Just divergedReason
          sdrRemaining (prsDrain step1) @?= 1
          case map sdiResult (sdrItems (prsDrain step1)) of
            [SessionOwnerDivergedNow
               (StepRuntimeFailed (SriHotSwapInstallFailed _))
               reason] ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected drain to stop on hot-swap divergence, got: "
                             <> show other)
          sdrStopped (prsDrain step2) @?= Just divergedReason
          case map sdiResult (sdrItems (prsDrain step2)) of
            (SessionOwnerBlocked reason : _) ->
              reason @?= divergedReason
            other ->
              assertFailure ("expected later runner step to surface blocked items, got: "
                             <> show other)
          status @?= SessionOwnerDiverged divergedReason

  , testCase "runner step retrying backlog does not advance the cursor" $ do
      producer <- patternProducerOrFail
        (defaultPatternProducerOptions { ppoBlockFrames = 8 })
      queue0 <- queueOrFail (SessionQueueOptions 1)
      let events = missingVoiceEventsAt [0, 1, 2]
          pat = droneVibrato { patternEvents = staticEvents events }
      result <- withSessionOwner
                  (patternTemplates droneVibrato)
                  defaultSessionOwnerOptions
                  $ \owner -> do
                    step1 <- stepPatternSession pat producer queue0 owner
                    step2 <- stepPatternSession pat (prsState step1) (prsQueue step1) owner
                    pure (step1, step2)
      case result of
        Left setupIssue ->
          assertFailure ("expected session owner, got: " <> show setupIssue)
        Right (step1, step2) -> do
          perNextStart (prsEnqueue step1) @?= SamplePos 8
          perNextStart (prsEnqueue step2) @?= perNextStart (prsEnqueue step1)
          assertBool
            "step 1 should be backlogged after queue cap 1"
            (isBacklogged (prsState step1))
          map peiSamplePos (perItems (prsEnqueue step2))
            @?= [SamplePos 1, SamplePos 2]
  ]

------------------------------------------------------------
-- Session Prep J: serialized Pattern session host
------------------------------------------------------------

sessionHostTests :: TestTree
sessionHostTests = testGroup "Session Prep J: Pattern session host"
  [ testCase "host construction surfaces owned component failures" $ do
      let graph = patternTemplates droneVibrato
          invalidProducerOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 0 }
            }
          invalidQueueOpts = defaultPatternSessionHostOptions
            { pshoQueueOptions = SessionQueueOptions 0
            }
          duplicated = duplicateFirstTwoTemplates
                         (patternTemplates arpeggioSendReturn)
      badProducer <- withPatternSessionHost
                       graph
                       invalidProducerOpts
                       (\_ -> pure ())
      badProducer @?=
        Left (PshsiPatternProducer (PpiInvalidBlockFrames 0))

      badQueue <- withPatternSessionHost
                    graph
                    invalidQueueOpts
                    (\_ -> pure ())
      badQueue @?= Left (PshsiQueue (SqsiInvalidCapacity 0))

      badOwner <- withPatternSessionHost
                    duplicated
                    defaultPatternSessionHostOptions
                    (\_ -> pure ())
      badOwner @?=
        Left (PshsiOwner (SasiDuplicateTemplateName (TemplateName "dup")))

  , testCase "host step commits a Pattern voice and exposes a snapshot" $ do
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  defaultPatternSessionHostOptions
                  $ \host -> do
                    step <- stepPatternSessionHost droneVibrato host
                    snapshot <- readPatternSessionHost host
                    pure (step, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step, snapshot) -> do
          sdrRemaining (prsDrain step) @?= 0
          sdrStopped (prsDrain step) @?= Nothing
          assertBool
            "host snapshot should report no backlog after one clean step"
            (not (pshsBacklogged snapshot))
          pshsOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            ("expected v0 voice in hosted owner state, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (M.member (VoiceKey "v0") (ssVoices (pshsOwnerState snapshot)))

  , testCase "host carries Pattern backlog across repeated calls" $ do
      let voiceOn k =
            PEVoiceOn (TemplateName "stab") (VoiceKey k)
              [ (ControlTag (MigrationKey "lpf")      0, 800.0)
              , (ControlTag (MigrationKey "envelope") 0, 1.0)
              ]
          events =
            [ (SamplePos 0, voiceOn "s0")
            , (SamplePos 1, voiceOn "s1")
            , (SamplePos 2, voiceOn "s2")
            ]
          pat = polyphonicStab { patternEvents = staticEvents events }
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "stab") 3
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 1
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates polyphonicStab)
                  hostOpts
                  $ \host -> do
                    step1 <- stepPatternSessionHost pat host
                    step2 <- stepPatternSessionHost pat host
                    step3 <- stepPatternSessionHost pat host
                    snapshot <- readPatternSessionHost host
                    pure (step1, step2, step3, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (step1, step2, step3, snapshot) -> do
          perBacklogged (prsEnqueue step1) @?= 2
          perBacklogged (prsEnqueue step2) @?= 1
          perBacklogged (prsEnqueue step3) @?= 0
          assertBool
            "host should clear backlog after the third serialized step"
            (not (pshsBacklogged snapshot))
          assertBool
            ("expected s0, s1, s2 voices after hosted backlog drain, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["s0", "s1", "s2"])

  , testCase "concurrent host callers serialize whole Pattern steps" $ do
      let events =
            [ ( SamplePos 0
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v0") []
              )
            , ( SamplePos 8
              , PEVoiceOn (TemplateName "drone") (VoiceKey "v1") []
              )
            ]
          pat = droneVibrato { patternEvents = staticEvents events }
          ownerOpts = defaultSessionOwnerOptions
            { sooAdapterOptions = defaultRTGraphAdapterOptions
                { raoPerTemplatePolyphony =
                    M.singleton (TemplateName "drone") 2
                }
            }
          hostOpts = defaultPatternSessionHostOptions
            { pshoProducerOptions =
                defaultPatternProducerOptions { ppoBlockFrames = 8 }
            , pshoQueueOptions =
                SessionQueueOptions 4
            , pshoOwnerOptions =
                ownerOpts
            }
      result <- withPatternSessionHost
                  (patternTemplates droneVibrato)
                  hostOpts
                  $ \host -> do
                    done <- newEmptyMVar
                    let worker =
                          stepPatternSessionHost pat host >>= putMVar done
                    _ <- forkIO worker
                    _ <- forkIO worker
                    mStep1 <- timeout 1000000 (takeMVar done)
                    mStep2 <- timeout 1000000 (takeMVar done)
                    snapshot <- readPatternSessionHost host
                    pure (mStep1, mStep2, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected Pattern session host, got: " <> show issue)
        Right (Just step1, Just step2, snapshot) -> do
          sort (map (perNextStart . prsEnqueue) [step1, step2])
            @?= [SamplePos 8, SamplePos 16]
          assertBool
            ("expected v0 and v1 voices after concurrent hosted steps, got "
              <> show (ssVoices (pshsOwnerState snapshot)))
            (all
              (\k -> M.member (VoiceKey k) (ssVoices (pshsOwnerState snapshot)))
              ["v0", "v1"])
        Right other ->
          assertFailure ("timed out waiting for concurrent hosted steps: "
                         <> show other)
  ]

patternProducerOrFail :: PatternProducerOptions -> IO PatternProducerState
patternProducerOrFail opts =
  case newPatternProducerState opts of
    Left issue ->
      assertFailure ("expected Pattern producer state, got: " <> show issue)
    Right state ->
      pure state

itemSequence :: PatternEnqueueItem -> Maybe CommandSequence
itemSequence item = case peiResult item of
  SessionEnqueued queued ->
    Just (qscSequence queued)
  SessionEnqueueRejected {} ->
    Nothing

------------------------------------------------------------
-- Session Prep L: preserving hot-swap semantics tests
--
-- Prep K is a decision gate, not an implementation. These tests pin
-- the execution-time semantics that preserving implementations must
-- preserve. Unsupported preserving shapes still reject in the real
-- RTGraph adapter; the one preserved-voice missing-control case uses
-- a mock adapter to model a successful preserve path with a stripped
-- post-swap control surface.
------------------------------------------------------------

sessionPreservingHotSwapSpecTests :: TestTree
sessionPreservingHotSwapSpecTests =
  testGroup "Session Prep L: preserving hot-swap semantics"
  [ testCase "queued hot-swap previews after earlier queued voice-start" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          swapCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "same-after-start") graph)
      (queue1, startQueued) <- enqueueOrFail producer startCmd queue0
      (queue2, swapQueued) <- enqueueOrFail producer swapCmd queue1

      result <- withSessionOwner graph defaultSessionOwnerOptions $
        \owner -> do
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right ((_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [startQueued, swapQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ Nothing)
              , SessionOwnerStep
                  (StepRuntimeFailed SriHotSwapWouldPreserveVoices)
              ] ->
                pure ()
            other ->
              assertFailure
                ("expected start commit then preserving-swap rejection, got: "
                 <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          assertBool
            "execution-time hot-swap preview should see the started voice"
            (M.member (VoiceKey "v0") (ssVoices st))

  , testCase "second queued hot-swap previews after the first swap commits" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          dropCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "drop-drone") newGraph)
          restoreCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "restore-drone") oldGraph)
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      (queue1, dropQueued) <- enqueueOrFail producer dropCmd queue0
      (queue2, restoreQueued) <- enqueueOrFail producer restoreCmd queue1

      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          started <- stepSessionOwner owner startCmd
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (started, drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               (_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [dropQueued, restoreQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ (Just dropRebuild))
              , SessionOwnerStep (StepCommitted _ (Just restoreRebuild))
              ] -> do
                rrrDropped dropRebuild @?= expectedDrop
                rrrDropped restoreRebuild @?= []
            other ->
              assertFailure
                ("expected two hot-swap commits, got: " <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          ssGraph st @?= oldGraph
          ssVoices st @?= M.empty
        Right other ->
          assertFailure ("expected started voice before queued swaps, got: "
                         <> show other)

  , testCase "voice-off after swap-dropped voice is stale, not divergence" $ do
      queue0 <- queueOrFail (SessionQueueOptions 2)
      let oldGraph = patternTemplates droneVibrato
          newGraph = patternTemplates polyphonicStab
          producer = testProducer ProducerPattern "pattern"
          startCmd =
            fromPatternEvent
              (PEVoiceOn (TemplateName "drone") (VoiceKey "v0") [])
          swapCmd =
            fromPatternEvent
              (PEHotSwap (SwapLabel "drop-drone") newGraph)
          offCmd =
            fromPatternEvent
              (PEVoiceOff (VoiceKey "v0"))
          expectedDrop =
            [RriMissingTemplate (VoiceKey "v0") (TemplateName "drone")]
      (queue1, swapQueued) <- enqueueOrFail producer swapCmd queue0
      (queue2, offQueued) <- enqueueOrFail producer offCmd queue1

      result <- withSessionOwner oldGraph defaultSessionOwnerOptions $
        \owner -> do
          started <- stepSessionOwner owner startCmd
          drained <- drainSessionCommandQueue owner queue2
          st <- sessionOwnerState owner
          status <- sessionOwnerStatus owner
          pure (started, drained, st, status)

      case result of
        Left issue ->
          assertFailure ("expected session owner, got: " <> show issue)
        Right (SessionOwnerStep (StepCommitted _ Nothing),
               (_queue3, drain), st, status) -> do
          map sdiQueued (sdrItems drain) @?= [swapQueued, offQueued]
          case map sdiResult (sdrItems drain) of
            [ SessionOwnerStep (StepCommitted _ (Just rebuild))
              , SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))
              ] ->
                rrrDropped rebuild @?= expectedDrop
            other ->
              assertFailure
                ("expected drop commit then stale voice-off rejection, got: "
                 <> show other)
          sdrRemaining drain @?= 0
          sdrStopped drain @?= Nothing
          status @?= SessionOwnerReady
          ssGraph st @?= newGraph
          ssVoices st @?= M.empty
        Right other ->
          assertFailure ("expected started voice before queued voice-off, got: "
                         <> show other)

  , testCase "post-swap missing control is explicit runtime failure" $ do
      strippedGraph <- compileTemplateGraphOrFail
        [ ("drone", runSynth $ do
              carrier <- tagged "carrier" (sinOsc (Param 220.0) (Param 0.0))
              out 0 carrier
          )
        ]
      let oldGraph = patternTemplates droneVibrato
          binding = VoiceBinding (VoiceKey "vLead") 7 (TemplateName "drone")
          st0 = applySessionCommit
                  (CommitVoiceStarted binding)
                  (initialSessionState oldGraph)
          swapLabel = SwapLabel "strip-lpf"
          swapCmd = fromPatternEvent (PEHotSwap swapLabel strippedGraph)
          lpfTag = ControlTag (MigrationKey "lpf") 0
          writeCmd =
            fromPatternEvent
              (PEControlWrite (VoiceKey "vLead") lpfTag 2000.0)
          expectedIssue =
            CtiUnknownNodeTag (TemplateName "drone") (MigrationKey "lpf")
          swapAdapter =
            constantAdapter
              (Right (RuntimeCommitted
                (CommitGraphInstalled swapLabel strippedGraph)))
      swapped <- stepSessionCommand swapAdapter swapCmd st0
      case swapped of
        StepCommitted st1 (Just rebuild) -> do
          rrrDropped rebuild @?= []
          M.lookup (VoiceKey "vLead") (ssVoices st1) @?= Just binding
          let resolverAdapter = SessionRuntimeAdapter $ \case
                PlanControlWrite preservedBinding target _ ->
                  pure $ case resolveControlTarget
                                (ssGraph st1)
                                (vbTemplateName preservedBinding)
                                target of
                    Left issue ->
                      Left (SriControlTargetRejected issue)
                    Right _ ->
                      Right RuntimeControlWriteAccepted
                _other ->
                  pure (Right (RuntimeCommitted
                    (CommitGraphInstalled (SwapLabel "unexpected") (ssGraph st1))))
          written <- stepSessionCommand resolverAdapter writeCmd st1
          written @?= StepRuntimeFailed
            (SriControlTargetRejected expectedIssue)
        other ->
          assertFailure ("expected modeled preserving hot-swap commit, got: "
                         <> show other)
  ]

------------------------------------------------------------
-- Session Prep O: live-audio preserving hot-swap orchestration
--
-- These tests do not start PortAudio. They pin the session-visible
-- failure policy with mock 'SessionRuntimeAdapter' results and pin
-- the producer-side live install protocol with deterministic fake
-- publish/wait/collect callbacks.
------------------------------------------------------------

sessionLiveHotSwapOrchestrationTests :: TestTree
sessionLiveHotSwapOrchestrationTests =
  testGroup "Session Prep O: live preserving hot-swap orchestration"
  [ testCase "publish rejection is a retryable runtime failure" $ do
      (st0, cmd, swapLabel, newGraph) <-
        liveHotSwapFixture "live-publish-rejected"
      (result, observedPlan) <-
        runMockLiveHotSwap st0 cmd SriHotSwapPublishRejected
      result @?= StepRuntimeFailed SriHotSwapPublishRejected
      assertObservedPreservingPlan observedPlan swapLabel newGraph

  , testCase "install timeout maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-install-timeout"
        "preserving hot-swap install timed out"

  , testCase "retired-missing maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-retired-missing"
        "preserving hot-swap installed but retired swap was missing"

  , testCase "incomplete migration maps to terminal install failure wrapper" $ do
      assertMockLiveInstallFailure
        "live-incomplete-migration"
        "preserving hot-swap migration was incomplete"

  , testCase "deterministic live protocol orders publish wait collect verify" $ do
      eventsRef <- newIORef []
      let record event =
            modifyIORef' eventsRef (<> [event])
          expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
          protocol = LiveHotSwapProtocol
            { lhpReadGeneration = do
                record "read-generation"
                pure 11
            , lhpAcquireSwap = do
                record "acquire"
                pure (Right "swap")
            , lhpPublishSwap = \swap -> do
                swap @?= "swap"
                record "publish"
                pure (Right ())
            , lhpWaitForGeneration = \priorGeneration timeoutMs -> do
                priorGeneration @?= 11
                timeoutMs @?= 250
                record "wait"
                pure True
            , lhpCollectRetiredStats = do
                record "collect"
                pure (Just (fakeMigrationStats 3 2))
            }
      result <- runLiveHotSwapProtocol protocol expectations 250
      result @?= Right ()
      events <- readIORef eventsRef
      events
        @?= [ "read-generation"
            , "acquire"
            , "publish"
            , "wait"
            , "collect"
            ]

  , testCase "deterministic live protocol maps post-publish failures" $ do
      let expectations =
            PreservingHotSwapExpectations
              { phsePreservedBindingCount = 2
              , phseExpectedStateCopyCount = 3
              }
      assertLiveProtocolFailure
        expectations
        "timeout"
        (\protocol -> protocol
          { lhpWaitForGeneration = \_ _ -> pure False
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException "preserving hot-swap install timed out"))
      assertLiveProtocolFailure
        expectations
        "retired-missing"
        (\protocol -> protocol
          { lhpCollectRetiredStats = pure Nothing
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap installed but retired swap was missing"))
      assertLiveProtocolFailure
        expectations
        "incomplete-migration"
        (\protocol -> protocol
          { lhpCollectRetiredStats =
              pure (Just (fakeMigrationStats 2 2))
          })
        (SriHotSwapInstallFailed
          (SasiLoaderException
            "preserving hot-swap migration was incomplete"))
  ]

liveHotSwapFixture
  :: String
  -> IO (SessionState, SessionCommand, SwapLabel, TemplateGraph)
liveHotSwapFixture labelText = do
  newGraph <- compileTemplateGraphOrFail hotSwapEditAfterTemplates
  let oldGraph = patternTemplates hotSwapEdit
      binding  = VoiceBinding (VoiceKey "vLive") 3 (TemplateName "drone")
      st0      = applySessionCommit
                   (CommitVoiceStarted binding)
                   (initialSessionState oldGraph)
      label    = SwapLabel labelText
      cmd      = CmdHotSwap label newGraph
  pure (st0, cmd, label, newGraph)

runMockLiveHotSwap
  :: SessionState
  -> SessionCommand
  -> SessionRuntimeIssue
  -> IO (SessionStepResult, Maybe SessionPlan)
runMockLiveHotSwap st cmd issue = do
  observedPlanRef <- newIORef Nothing
  let adapter = SessionRuntimeAdapter $ \plan -> do
        writeIORef observedPlanRef (Just plan)
        pure (Left issue)
  result <- stepSessionCommand adapter cmd st
  observedPlan <- readIORef observedPlanRef
  pure (result, observedPlan)

assertMockLiveInstallFailure :: String -> String -> Assertion
assertMockLiveInstallFailure labelText message = do
  (st0, cmd, swapLabel, newGraph) <- liveHotSwapFixture labelText
  let issue = SriHotSwapInstallFailed (SasiLoaderException message)
  (result, observedPlan) <- runMockLiveHotSwap st0 cmd issue
  result @?= StepRuntimeFailed issue
  assertObservedPreservingPlan observedPlan swapLabel newGraph

assertObservedPreservingPlan
  :: Maybe SessionPlan
  -> SwapLabel
  -> TemplateGraph
  -> Assertion
assertObservedPreservingPlan observedPlan expectedLabel expectedGraph =
  case observedPlan of
    Just (PlanHotSwap label graph rebuild) -> do
      label @?= expectedLabel
      graph @?= expectedGraph
      rrrDropped rebuild @?= []
    other ->
      assertFailure ("expected preserving PlanHotSwap, got: " <> show other)

assertLiveProtocolFailure
  :: PreservingHotSwapExpectations
  -> String
  -> (LiveHotSwapProtocol IO String -> LiveHotSwapProtocol IO String)
  -> SessionRuntimeIssue
  -> Assertion
assertLiveProtocolFailure expectations labelText patch expectedIssue = do
  let protocol = patch (successfulFakeLiveProtocol labelText)
  result <- runLiveHotSwapProtocol protocol expectations 250
  result @?= Left expectedIssue

successfulFakeLiveProtocol :: String -> LiveHotSwapProtocol IO String
successfulFakeLiveProtocol labelText = LiveHotSwapProtocol
  { lhpReadGeneration =
      pure 11
  , lhpAcquireSwap =
      pure (Right ("swap-" <> labelText))
  , lhpPublishSwap =
      const (pure (Right ()))
  , lhpWaitForGeneration =
      \_ _ -> pure True
  , lhpCollectRetiredStats =
      pure (Just (fakeMigrationStats 3 2))
  }

fakeMigrationStats :: Int -> Int -> SwapMigrationStats
fakeMigrationStats stateCopies lifecycleCopies = SwapMigrationStats
  -- The live protocol verifier currently inspects only state and
  -- lifecycle copy counts; the other counters stay explicit so a
  -- future verifier change has a visible test fixture to revisit.
  { smsCommittedCount = 0
  , smsSkippedCount = 0
  , smsInstanceCopyCount = 0
  , smsStateCopyCount = stateCopies
  , smsLifecycleCopyCount = lifecycleCopies
  }

------------------------------------------------------------
-- Session Prep P: generic producer fan-in host
--
-- This is the first shared command-ingress host for concrete OSC,
-- MIDI, UI, Pattern, or future background producers. It remains
-- caller-driven: producers enqueue commands, and a caller or later
-- worker decides when to drain.
------------------------------------------------------------

sessionFanInHostTests :: TestTree
sessionFanInHostTests =
  testGroup "Session Prep P: producer fan-in host"
  [ testCase "drain preserves FIFO across OSC and MIDI producers" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          midiProducer = testProducer ProducerMIDI "midi"
          startCmd =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          writeCmd =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              650.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand oscProducer startCmd host
          enq1 <- enqueueSessionFanInCommand midiProducer writeCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, enq1, drained, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, drained, snapshot) -> do
          q0 <- fanInQueuedOrFail enq0
          q1 <- fanInQueuedOrFail enq1
          qscSequence q0 @?= CommandSequence 0
          qscSequence q1 @?= CommandSequence 1
          map (qscProducer . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [oscProducer, midiProducer]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [ SessionOwnerStep (StepCommitted _ Nothing)
              , SessionOwnerStep StepControlAccepted
              ] ->
                pure ()
            other ->
              assertFailure
                ("expected voice start then control write, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          assertBool
            "expected v0 in fan-in owner state after drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))

  , testCase "bounded queue rejects excess producer command" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd0 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
          cmd1 = CmdVoiceOn (TemplateName "drone") (VoiceKey "v1") []
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueSessionFanInCommand producer cmd0 host
        enq1 <- enqueueSessionFanInCommand producer cmd1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq0, enq1, snapshot) -> do
          _queued <- fanInQueuedOrFail enq0
          sfierResult enq1
            @?= SessionEnqueueRejected producer cmd1 (SeiQueueFull 1)
          sfierQueueDepth enq1 @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "concurrent producer enqueues serialize sequence numbers" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 4
            }
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker producer voiceKey =
              enqueueSessionFanInCommand
                producer
                (CmdVoiceOn (TemplateName "drone") voiceKey [])
                host
                >>= putMVar done
        _ <- forkIO (worker (testProducer ProducerOSC "osc") (VoiceKey "v0"))
        _ <- forkIO (worker (testProducer ProducerMIDI "midi") (VoiceKey "v1"))
        mEnq0 <- timeout 1000000 (takeMVar done)
        mEnq1 <- timeout 1000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (mEnq0, mEnq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just enq0, Just enq1, snapshot) -> do
          let results = [sfierResult enq0, sfierResult enq1]
              queued =
                [ queuedCommand
                | SessionEnqueued queuedCommand <- results
                ]
          length queued @?= 2
          sort (map qscSequence queued)
            @?= [CommandSequence 0, CommandSequence 1]
          sort (map (producerKind . qscProducer) queued)
            @?= [ProducerOSC, ProducerMIDI]
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure ("timed out waiting for fan-in enqueues: "
                         <> show other)

  , testCase "many concurrent producer enqueues keep contiguous sequences" $ do
      let workerCount = 32
          graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions workerCount
            }
          producerFor i =
            testProducer
              (if even i then ProducerOSC else ProducerMIDI)
              ("producer-" <> show i)
          commandFor i =
            CmdVoiceOn
              (TemplateName "drone")
              (VoiceKey ("v" <> show i))
              []
      result <- withSessionFanInHost graph opts $ \host -> do
        done <- newEmptyMVar
        let worker i =
              enqueueSessionFanInCommand
                (producerFor i)
                (commandFor i)
                host
                >>= putMVar done
        forM_ [0 .. workerCount - 1] $ \i ->
          forkIO (worker i)
        enqueues <- forM [0 .. workerCount - 1] $ \_ ->
          timeout 2000000 (takeMVar done)
        snapshot <- readSessionFanInHost host
        pure (enqueues, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (mEnqueues, snapshot) ->
          case sequence mEnqueues of
            Nothing ->
              assertFailure "timed out waiting for fan-in enqueue workers"
            Just enqueues -> do
              let queued =
                    [ queuedCommand
                    | SessionEnqueued queuedCommand <-
                        map sfierResult enqueues
                    ]
              length queued @?= workerCount
              sort (map qscSequence queued)
                @?= map (CommandSequence . fromIntegral)
                      [0 .. workerCount - 1]
              sfisQueueDepth snapshot @?= workerCount

  , testCase "drain divergence leaves unprocessed tail queued" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          issue = SasiDuplicateTemplateName (TemplateName "dup")
          reason = SodHotSwapInstallFailed issue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      result <- withSessionFanInHost oldGraph defaultSessionFanInOptions $
        \host -> do
          enq0 <- enqueueSessionFanInCommand producer badCmd host
          _enq1 <- enqueueSessionFanInCommand producer laterCmd host
          drained <- drainSessionFanInHost host
          snapshot <- readSessionFanInHost host
          pure (enq0, drained, snapshot)
      case result of
        Left setupIssue ->
          assertFailure ("expected fan-in host, got: " <> show setupIssue)
        Right (enq0, drained, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          sdrItems (sfidrDrain drained) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed issue))
                  reason)
            ]
          sdrRemaining (sfidrDrain drained) @?= 1
          sdrStopped (sfidrDrain drained) @?= Just reason
          sfidrQueueDepth drained @?= 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged reason
  ]

fanInQueuedOrFail
  :: SessionFanInEnqueueResult
  -> IO QueuedSessionCommand
fanInQueuedOrFail result =
  case sfierResult result of
    SessionEnqueued queued ->
      pure queued
    other ->
      assertFailure ("expected fan-in enqueue success, got: " <> show other)

gatewayQueuedOrFail
  :: SessionArbitrationGatewayEnqueueResult
  -> IO QueuedSessionCommand
gatewayQueuedOrFail result =
  case result of
    SagEnqueueAttempted fanInResult ->
      fanInQueuedOrFail fanInResult
    SagArbitrationRejected issue ->
      assertFailure ("expected arbitration gateway enqueue success, got: "
                     <> show issue)

assertPriorityOwner
  :: ArbitrationPolicy
  -> ControlArbitrationTarget
  -> ProducerId
  -> Assertion
assertPriorityOwner policy target expected =
  case policy of
    ProducerPriority _ owners ->
      lookupControlOwner target owners @?= Just expected
    other ->
      assertFailure ("expected priority policy, got: " <> show other)

------------------------------------------------------------
-- Session fan-in drain service
--
-- This is the first minimal background lifecycle wrapper around the
-- generic fan-in host. It wakes on successful enqueue, drains the
-- existing FIFO host, reports stopped drains, and exits on owner
-- divergence. The raw enqueue path remains FIFO; arbitration is only
-- exercised through the explicit service-owned gateway path.
------------------------------------------------------------

sessionFanInServiceTests :: TestTree
sessionFanInServiceTests =
  testGroup "Session fan-in drain service"
  [ testCase "bracket cleanup: body return tears down worker" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> readSessionFanInService service
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right snapshot -> do
          sfisQueueDepth snapshot @?= 0
          sfisOwnerStatus snapshot @?= SessionOwnerReady

  , testCase "bracket cleanup kills worker when drain hook blocks" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      hookEntered <- newEmptyMVar
      neverRelease <- newEmptyMVar
      result <- timeout 1000000 $
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain =
                \_drained -> do
                  putMVar hookEntered ()
                  takeMVar neverRelease
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mEntered <- timeout 1000000 (takeMVar hookEntered)
              pure (enq, mEntered)
      case result of
        Nothing ->
          assertFailure
            "service teardown hung while drain hook was blocked"
        Just (Left issue) ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Just (Right (enq, Just ())) -> do
          _queued <- fanInQueuedOrFail enq
          pure ()
        Just (Right (_enq, Nothing)) ->
          assertFailure "timed out waiting for blocking drain hook"

  , testCase "successful enqueue wakes background drain worker" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueSessionFanInServiceCommand producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed background drain, got: "
                 <> show other)
          sdrRemaining (sfidrDrain drained) @?= 0
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected v0 in service owner state after background drain"
            (M.member (VoiceKey "v0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for service drain"

  , testCase "default arbitrated enqueue keeps FIFO service behavior" $ do
      let graph = patternTemplates droneVibrato
          producer = testProducer ProducerUI "ui"
          cmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedSessionFanInServiceCommand
                       producer cmd service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (enq, Just drained, snapshot) -> do
          queued <- gatewayQueuedOrFail enq
          case sdrItems (sfidrDrain drained) of
            [SessionDrainItem drainedQueued
              (SessionOwnerStep (StepCommitted _ Nothing))] ->
                drainedQueued @?= queued
            other ->
              assertFailure
                ("expected one committed arbitrated drain, got: "
                 <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated service drain"

  , testCase "configured arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          oscProducer = testProducer ProducerOSC "osc"
          patternProducer = testProducer ProducerPattern "pattern"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          command =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.5
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      ProducerPriority
                        [ProducerMIDI, ProducerOSC, ProducerUI, ProducerPattern]
                        emptyControlOwnerTable
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = patternProducer
            , aiCommand   = command
            , aiTarget    = Just target
            , aiReason    = ArrLowerPriorityThan oscProducer
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          graph
          opts
          $ \service -> do
              enq0 <- enqueueArbitratedSessionFanInServiceCommand
                        oscProducer command service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            patternProducer command service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( enq0
                , mFirstDrain
                , rejected
                , mIssue
                , mRejectedDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( enq0
          , Just _firstDrain
          , rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            queued0 <- gatewayQueuedOrFail enq0
            qscProducer queued0 @?= oscProducer
            qscSequence queued0 @?= CommandSequence 0
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_enq0, Nothing, _rejected, _mIssue, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for first arbitrated drain"
        Right (_enq0, Just _firstDrain, _rejected, Nothing, _mRejectedDrain, _snapshot) ->
          assertFailure "timed out waiting for arbitration rejection issue"
        Right (_enq0, Just _firstDrain, _rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "target-claim arbitration rejects before service wake" $ do
      let graph = patternTemplates droneVibrato
          claimant = testProducer ProducerUI "ui"
          blocked  = testProducer ProducerMIDI "midi"
          target =
            ControlArbitrationTarget (VoiceKey "v0") midiLevelTag
          claimedCommand =
            CmdControlWrite (VoiceKey "v0") midiLevelTag 0.25
          otherCommand =
            CmdControlWrite (VoiceKey "v0") midiFreqTag 440.0
          opts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = blocked
            , aiCommand   = claimedCommand
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          opts
          $ \service -> do
              claimantEnq <- enqueueArbitratedSessionFanInServiceCommand
                               claimant claimedCommand service
              mFirstDrain <- timeout 1000000 (takeMVar drainedVar)
              rejected <- enqueueArbitratedSessionFanInServiceCommand
                            blocked claimedCommand service
              mRejectedDrain <- timeout 100000 (takeMVar drainedVar)
              otherEnq <- enqueueArbitratedSessionFanInServiceCommand
                            blocked otherCommand service
              mOtherDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure
                ( claimantEnq
                , mFirstDrain
                , rejected
                , mRejectedDrain
                , otherEnq
                , mOtherDrain
                , snapshot
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( claimantEnq
          , Just _firstDrain
          , rejected
          , Nothing
          , otherEnq
          , Just _otherDrain
          , snapshot
          ) -> do
            q0 <- gatewayQueuedOrFail claimantEnq
            q1 <- gatewayQueuedOrFail otherEnq
            qscProducer q0 @?= claimant
            qscProducer q1 @?= blocked
            qscSequence q0 @?= CommandSequence 0
            qscSequence q1 @?= CommandSequence 1
            qscCommand q0 @?= claimedCommand
            qscCommand q1 @?= otherCommand
            rejected @?= SagArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_claimantEnq, Nothing, _rejected, _mRejectedDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure "timed out waiting for claimant drain"
        Right (_claimantEnq, Just _firstDrain, _rejected, Just extraDrain, _otherEnq, _mOtherDrain, _snapshot) ->
          assertFailure
            ("target-claim rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right (_claimantEnq, Just _firstDrain, _rejected, Nothing, _otherEnq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for unrelated target drain"

  , testCase "service host wakes worker for OSC producer enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 900.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <-
                enqueueOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, Just drained, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
              pure ()
            other ->
              assertFailure
                ("expected stale OSC control-write drain, got: " <> show other)
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for OSC service drain"
        Right other ->
          assertFailure ("expected OSC enqueue through service, got: "
                         <> show other)

  , testCase "divergent drain reports issue and stops worker" $ do
      let oldGraph = patternTemplates droneVibrato
          badGraph =
            duplicateFirstTwoTemplates (patternTemplates arpeggioSendReturn)
          producer = testProducer ProducerUI "ui"
          setupIssue = SasiDuplicateTemplateName (TemplateName "dup")
          divergedReason = SodHotSwapInstallFailed setupIssue
          badCmd = CmdHotSwap (SwapLabel "bad-graph") badGraph
          laterCmd = CmdVoiceOn (TemplateName "drone") (VoiceKey "v0") []
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          oldGraph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq0 <- enqueueSessionFanInServiceCommand producer badCmd service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              enq1 <- enqueueSessionFanInServiceCommand producer laterCmd service
              snapshot <- readSessionFanInService service
              pure (enq0, mIssue, enq1, snapshot)
      case result of
        Left serviceIssue ->
          assertFailure ("expected fan-in service, got: " <> show serviceIssue)
        Right (enq0, Just (SfsiiDrainStopped stopped), enq1, snapshot) -> do
          queued0 <- fanInQueuedOrFail enq0
          queued1 <- fanInQueuedOrFail enq1
          sdrItems (sfidrDrain stopped) @?=
            [ SessionDrainItem
                queued0
                (SessionOwnerDivergedNow
                  (StepRuntimeFailed (SriHotSwapInstallFailed setupIssue))
                  divergedReason)
            ]
          sdrRemaining (sfidrDrain stopped) @?= 0
          sdrStopped (sfidrDrain stopped) @?= Just divergedReason
          sfidrQueueDepth stopped @?= 0
          qscSequence queued1 @?= CommandSequence 1
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerDiverged divergedReason
        Right (_enq0, Nothing, _enq1, _snapshot) ->
          assertFailure "timed out waiting for service stopped-drain issue"
  ]

------------------------------------------------------------
-- Session MIDI producer adapter
--
-- This adapter is Haskell-only and consumes already-decoded MIDI
-- events. Live PortMIDI device ownership remains in the existing
-- Bridge.MidiDemo path.
------------------------------------------------------------

sessionMIDIProducerTests :: TestTree
sessionMIDIProducerTests =
  testGroup "Session MIDI producer adapter"
  [ testCase "note-on translates to voice start with configured controls" $ do
      let opts = testMIDIProducerOptions
          event = MIDIProducerNoteOn 0 69 64
      case decodeMIDISessionCommands opts initialMIDIProducerState event of
        Left issue ->
          assertFailure ("expected MIDI note-on translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-69")
                [ (midiFreqTag, 440.0)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (0, 69) (VoiceKey "m0-69")

  , testCase "note-on velocity zero is treated as note-off" $ do
      let active =
            testMIDIProducerState $
              M.singleton (2, 60) (VoiceKey "m2-60")
          event = MIDIProducerNoteOn 2 60 0
      decodeMIDISessionCommands testMIDIProducerOptions active event
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m2-60")]
              , mpcbState = initialMIDIProducerState
              }

  , testCase "duplicate and stale notes are rejected before enqueue" $ do
      let opts = testMIDIProducerOptions
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
      decodeMIDISessionCommands opts active (MIDIProducerNoteOn 0 69 127)
        @?= Left (MpiNoteAlreadyActive 0 69)
      decodeMIDISessionCommands opts initialMIDIProducerState
                                  (MIDIProducerNoteOff 0 69 0)
        @?= Left (MpiNoteNotActive 0 69)

  , testCase "CC maps to deterministic control writes for active notes" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 72), VoiceKey "m0-72")
                , ((0, 60), VoiceKey "m0-60")
                ]
          event = MIDIProducerControlChange 0 7 64
          expectedValue = 64.0 / 127.0
      case decodeMIDISessionCommands testMIDIProducerOptions active event of
        Left issue ->
          assertFailure ("expected MIDI CC translation, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdControlWrite (VoiceKey "m0-60") midiLevelTag expectedValue
            , CmdControlWrite (VoiceKey "m0-72") midiLevelTag expectedValue
            ]
          mpcbState batch @?= active

  , testCase "pitch-bend maps to channel-active frequency writes" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 72), VoiceKey "m0-72")
                , ((1, 67), VoiceKey "m1-67")
                , ((0, 60), VoiceKey "m0-60")
                ]
          value = 16383
          bentState = active { mpsPitchBends = M.singleton 0 value }
          expected note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral value - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerPitchBend 0 value) of
        Left issue ->
          assertFailure ("expected MIDI pitch-bend translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdControlWrite (VoiceKey "m0-60") midiFreqTag (expected 60)
            , CmdControlWrite (VoiceKey "m0-72") midiFreqTag (expected 72)
            ]
          mpcbState batch @?= bentState
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = initialMIDIProducerState
              }

  , testCase "pitch-bend state applies to later note-on" $ do
      let value = 16383
          bentState =
            initialMIDIProducerState
              { mpsPitchBends = M.singleton 0 value
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral value - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 value)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = bentState
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             bentState
             (MIDIProducerNoteOn 0 60 64) of
        Left issue ->
          assertFailure ("expected bent MIDI note-on, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-60")
                [ (midiFreqTag, expectedFreq 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpcbState batch @?=
            bentState
              { mpsActiveNotes = M.singleton (0, 60) (VoiceKey "m0-60")
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        bentState
        (MIDIProducerPitchBend 0 8192)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = initialMIDIProducerState
              }

  , testCase "sustain pedal defers note-off until pedal release" $ do
      let active =
            testMIDIProducerState $
              M.fromList
                [ ((0, 60), VoiceKey "m0-60")
                , ((1, 65), VoiceKey "m1-65")
                ]
          downState =
            active { mpsSustainedChannels = S.singleton 0 }
          deferredState =
            downState
              { mpsDeferredNoteOffs =
                  M.singleton (0, 60) (VoiceKey "m0-60")
              }
          releasedState =
            testMIDIProducerState $
              M.singleton (1, 65) (VoiceKey "m1-65")
      decodeMIDISessionCommands
        testMIDIProducerOptions
        active
        (MIDIProducerControlChange 0 64 127)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = downState
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        downState
        (MIDIProducerNoteOff 0 60 64)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = []
              , mpcbState = deferredState
              }
      decodeMIDISessionCommands
        testMIDIProducerOptions
        deferredState
        (MIDIProducerControlChange 0 64 0)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m0-60")]
              , mpcbState = releasedState
              }

  , testCase "sustained note can be retriggered after deferred note-off" $ do
      let deferredState =
            (testMIDIProducerState $
               M.singleton (0, 60) (VoiceKey "m0-60"))
              { mpsSustainedChannels = S.singleton 0
              , mpsDeferredNoteOffs =
                  M.singleton (0, 60) (VoiceKey "m0-60")
              }
          retriggeredState =
            (testMIDIProducerState $
               M.singleton (0, 60) (VoiceKey "m0-60"))
              { mpsSustainedChannels = S.singleton 0
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             deferredState
             (MIDIProducerNoteOn 0 60 64) of
        Left issue ->
          assertFailure ("expected sustained retrigger, got: " <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m0-60")
                [ (midiFreqTag, midiNoteFrequency 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpcbState batch @?= retriggeredState

  , testCase "channel filter admits allow-listed channels" $ do
      let opts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.singleton 2)
            }
          emptyOpts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList S.empty
            }
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
      decodeMIDISessionCommands
        emptyOpts
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 69 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 69 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerControlChange 0 7 64)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerControlChange 0 64 127)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Left (MpiChannelFiltered 0)
      decodeMIDISessionCommands
        opts
        active
        (MIDIProducerAllNotesOff (Just 0))
        @?= Left (MpiChannelFiltered 0)
      case decodeMIDISessionCommands
             opts
             initialMIDIProducerState
             (MIDIProducerNoteOn 2 60 64) of
        Left issue ->
          assertFailure ("expected allow-listed MIDI note, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOn
                (TemplateName "drone")
                (VoiceKey "m2-60")
                [ (midiFreqTag, midiNoteFrequency 60)
                , (midiGateTag, 1.0)
                , (midiVelocityTag, 64.0 / 127.0)
                ]
            ]
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (2, 60) (VoiceKey "m2-60")
      decodeMIDISessionCommands opts active (MIDIProducerAllNotesOff Nothing)
        @?= Right MIDIProducerCommandBatch
              { mpcbCommands = [CmdVoiceOff (VoiceKey "m0-69")]
              , mpcbState = initialMIDIProducerState
              }

  , testCase "all-notes-off emits deterministic voice stops and clears state" $ do
      let active =
            (testMIDIProducerState $
               M.fromList
                 [ ((1, 65), VoiceKey "m1-65")
                 , ((0, 72), VoiceKey "m0-72")
                 , ((0, 60), VoiceKey "m0-60")
                 ])
              { mpsSustainedChannels = S.fromList [0, 1]
              , mpsDeferredNoteOffs = M.fromList
                  [ ((1, 65), VoiceKey "m1-65")
                  , ((0, 60), VoiceKey "m0-60")
                  ]
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerAllNotesOff Nothing) of
        Left issue ->
          assertFailure ("expected all-notes-off translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            , CmdVoiceOff (VoiceKey "m1-65")
            ]
          mpcbState batch @?= initialMIDIProducerState

  , testCase "channel all-notes-off keeps other active and sustained channels" $ do
      let active =
            (testMIDIProducerState $
               M.fromList
                 [ ((1, 65), VoiceKey "m1-65")
                 , ((0, 72), VoiceKey "m0-72")
                 , ((0, 60), VoiceKey "m0-60")
                 ])
              { mpsSustainedChannels = S.fromList [0, 1]
              , mpsDeferredNoteOffs = M.fromList
                  [ ((1, 65), VoiceKey "m1-65")
                  , ((0, 60), VoiceKey "m0-60")
                  ]
              }
          expectedState =
            (testMIDIProducerState $
               M.singleton (1, 65) (VoiceKey "m1-65"))
              { mpsSustainedChannels = S.singleton 1
              , mpsDeferredNoteOffs =
                  M.singleton (1, 65) (VoiceKey "m1-65")
              }
      case decodeMIDISessionCommands
             testMIDIProducerOptions
             active
             (MIDIProducerAllNotesOff (Just 0)) of
        Left issue ->
          assertFailure ("expected channel all-notes-off translation, got: "
                         <> show issue)
        Right batch -> do
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            ]
          mpcbState batch @?= expectedState

  , testCase "invalid data bytes and unmapped controls reject explicitly" $ do
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerNoteOn 16 60 1)
        @?= Left (MpiInvalidChannel 16)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerNoteOn 0 128 1)
        @?= Left (MpiInvalidDataByte (T.pack "note") 128)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerControlChange 0 74 64)
        @?= Left (MpiUnmappedControl 74)
      decodeMIDISessionCommands
        defaultMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 8192)
        @?= Left MpiUnmappedPitchBend
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 16 8192)
        @?= Left (MpiInvalidChannel 16)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerPitchBend 0 16384)
        @?= Left (MpiInvalidPitchBendValue 16384)
      decodeMIDISessionCommands
        testMIDIProducerOptions
        initialMIDIProducerState
        (MIDIProducerAllNotesOff (Just 16))
        @?= Left (MpiInvalidChannel 16)

  , testCase "successful enqueue advances MIDI state under ProducerMIDI" $ do
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueMIDIProducerEvent
                             testMIDIProducerOptions
                             initialMIDIProducerState
                             (MIDIProducerNoteOn 0 69 127)
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq], snapshot) -> do
          mpsActiveNotes (mpcbState batch)
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          queued <- fanInQueuedOrFail enq
          producerKind (qscProducer queued) @?= ProducerMIDI
          mpcbCommands batch @?= [qscCommand queued]
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected MIDI enqueue attempt, got: "
                         <> show other)

  , testCase "filtered channel rejects before enqueue" $ do
      let opts = testMIDIProducerOptions
            { mpoChannelFilter = MIDIChannelAllowList (S.singleton 1)
            }
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    rejected <- enqueueMIDIProducerEvent
                                  opts
                                  initialMIDIProducerState
                                  (MIDIProducerNoteOn 0 69 127)
                                  host
                    snapshot <- readSessionFanInHost host
                    pure (rejected, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerRejected issue st, snapshot) -> do
          issue @?= MpiChannelFiltered 0
          st @?= initialMIDIProducerState
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected filtered MIDI rejection, got: "
                         <> show other)

  , testCase "queue-full does not advance note state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      initialMIDIProducerState
                      (MIDIProducerNoteOn 0 69 127)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= initialMIDIProducerState
          case mpcbCommands batch of
            [command] ->
              sfierResult enq
                @?= SessionEnqueueRejected
                      (midiProducerId testMIDIProducerOptions)
                      command
                      (SeiQueueFull 1)
            other ->
              assertFailure ("expected one MIDI command, got: " <> show other)
        Right other ->
          assertFailure ("expected queue-full MIDI enqueue, got: "
                         <> show other)

  , testCase "queue-full does not advance all-notes-off state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          active =
            testMIDIProducerState $
              M.singleton (0, 69) (VoiceKey "m0-69")
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      active
                      (MIDIProducerAllNotesOff Nothing)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          sfierResult enq
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m0-69"))
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full all-notes-off enqueue, got: "
                         <> show other)

  , testCase "queue-full does not advance sustain release state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          active =
            (testMIDIProducerState $
               M.singleton (0, 69) (VoiceKey "m0-69"))
              { mpsSustainedChannels = S.singleton 0
              , mpsDeferredNoteOffs =
                  M.singleton (0, 69) (VoiceKey "m0-69")
              }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueMIDIProducerEvent
                      testMIDIProducerOptions
                      active
                      (MIDIProducerControlChange 0 64 0)
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq]) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          sfierResult enq
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m0-69"))
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full sustain release, got: "
                         <> show other)

  , testCase "partial all-notes-off enqueue failure keeps producer state" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 3
            }
          active =
            testMIDIProducerState $
              M.fromList
                [ ((1, 65), VoiceKey "m1-65")
                , ((0, 72), VoiceKey "m0-72")
                , ((0, 60), VoiceKey "m0-60")
                ]
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enq <- enqueueMIDIProducerEvent
                             testMIDIProducerOptions
                             active
                             (MIDIProducerAllNotesOff Nothing)
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted batch [enq0, enq1, enq2],
               snapshot) -> do
          mpcbState batch @?= active
          mpcbCommands batch @?=
            [ CmdVoiceOff (VoiceKey "m0-60")
            , CmdVoiceOff (VoiceKey "m0-72")
            , CmdVoiceOff (VoiceKey "m1-65")
            ]
          q0 <- fanInQueuedOrFail enq0
          q1 <- fanInQueuedOrFail enq1
          qscCommand q0 @?= CmdVoiceOff (VoiceKey "m0-60")
          qscCommand q1 @?= CmdVoiceOff (VoiceKey "m0-72")
          sfierResult enq2
            @?= SessionEnqueueRejected
                  (midiProducerId testMIDIProducerOptions)
                  (CmdVoiceOff (VoiceKey "m1-65"))
                  (SeiQueueFull 3)
          sfisQueueDepth snapshot @?= 3
        Right other ->
          assertFailure
            ("expected partial all-notes-off enqueue failure, got: "
             <> show other)

  , testCase "pressure probe: high-rate pitch-bend fills strict FIFO queue" $ do
      let queueCapacity = 128
          activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          -- Keep every value non-center so mpsPitchBends stays populated.
          pitchValues =
            [9000..9008]
          -- The final 9008 event rolls back when all of its writes reject.
          acceptedState =
            initialState { mpsPitchBends = M.singleton 0 9007 }
          opts =
            defaultSessionFanInOptions
              { sfioQueueOptions = SessionQueueOptions queueCapacity
              }
          resultState = \case
            MIDIProducerRejected _ st ->
              st
            MIDIProducerEnqueueAttempted batch _ ->
              mpcbState batch
          resultEnqueues = \case
            MIDIProducerRejected {} ->
              []
            MIDIProducerEnqueueAttempted _ enqueues ->
              enqueues
          resultBatch = \case
            MIDIProducerRejected {} ->
              Nothing
            MIDIProducerEnqueueAttempted batch _ ->
              Just batch
          isControlWrite cmd = case cmd of
            CmdControlWrite _ _ _ ->
              True
            _ ->
              False
          enqueuePressure st [] _host =
            pure (st, [])
          enqueuePressure st (value : values) host = do
            enq <- enqueueMIDIProducerEvent
                     testMIDIProducerOptions
                     st
                     (MIDIProducerPitchBend 0 value)
                     host
            (stFinal, rest) <- enqueuePressure (resultState enq) values host
            pure (stFinal, enq : rest)
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          opts
          $ \host -> do
              -- This is a fan-in pressure probe; queue saturation happens
              -- before owner drain, so the active-note seed is producer-side.
              (finalState, pressureResults) <-
                enqueuePressure initialState pitchValues host
              snapshotBeforeDrain <- readSessionFanInHost host
              drained <- drainSessionFanInHost host
              snapshotAfterDrain <- readSessionFanInHost host
              pure
                ( finalState
                , pressureResults
                , snapshotBeforeDrain
                , drained
                , snapshotAfterDrain
                )
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right ( finalState
              , pressureResults
              , snapshotBeforeDrain
              , drained
              , snapshotAfterDrain
              ) -> do
          let batches =
                mapMaybe resultBatch pressureResults
              enqueueResults =
                concatMap resultEnqueues pressureResults
              enqueued =
                [ queued
                | SessionFanInEnqueueResult
                    { sfierResult = SessionEnqueued queued } <- enqueueResults
                ]
              rejectedIssues =
                [ issue
                | SessionFanInEnqueueResult
                    { sfierResult =
                        SessionEnqueueRejected _ _ issue
                    } <- enqueueResults
                ]
              drainedItems =
                sdrItems (sfidrDrain drained)
          length batches @?= length pitchValues
          map (length . mpcbCommands) batches
            @?= replicate (length pitchValues) 16
          length enqueueResults @?= 144
          length enqueued @?= queueCapacity
          rejectedIssues @?= replicate 16 (SeiQueueFull queueCapacity)
          map sfierQueueDepth (take queueCapacity enqueueResults)
            @?= [1..queueCapacity]
          map sfierQueueDepth (drop queueCapacity enqueueResults)
            @?= replicate 16 queueCapacity
          finalState @?= acceptedState
          sfisQueueDepth snapshotBeforeDrain @?= queueCapacity
          assertBool
            "expected only control writes to enter the pressure queue"
            (all (isControlWrite . qscCommand) enqueued)
          map sdiQueued drainedItems @?= enqueued
          length drainedItems @?= queueCapacity
          sdrRemaining (sfidrDrain drained) @?= 0
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
          sfisQueueDepth snapshotAfterDrain @?= 0

  , testCase "service host wakes worker for MIDI note-on" $ do
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueMIDIProducerEvent
                       testMIDIPlayableOptions
                       initialMIDIProducerState
                       (MIDIProducerNoteOn 0 69 100)
                       (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (MIDIProducerEnqueueAttempted _ [enq], Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected MIDI note-on to commit through service, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected MIDI voice after service drain"
            (M.member (VoiceKey "m0-69") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for MIDI service drain"
        Right other ->
          assertFailure ("expected MIDI service enqueue, got: " <> show other)
  ]

testMIDIProducerState :: M.Map (Word8, Word8) VoiceKey -> MIDIProducerState
testMIDIProducerState active =
  initialMIDIProducerState { mpsActiveNotes = active }

testMIDIProducerOptions :: MIDIProducerOptions
testMIDIProducerOptions = defaultMIDIProducerOptions
  { mpoTemplateName =
      TemplateName "drone"
  , mpoFrequencyControl =
      Just midiFreqTag
  , mpoGateControl =
      Just midiGateTag
  , mpoVelocityControl =
      Just midiVelocityTag
  , mpoCCMappings =
      M.singleton 7 MIDIControlMapping
        { mcmTarget = midiLevelTag
        , mcmMin    = 0.0
        , mcmMax    = 1.0
        }
  , mpoPitchBendMapping =
      Just MIDIPitchBendMapping
        { mpbmTarget    = midiFreqTag
        , mpbmSemitones = 2.0
        }
  }

testMIDIPlayableOptions :: MIDIProducerOptions
testMIDIPlayableOptions = testMIDIProducerOptions
  -- Keep service/listener composition tests focused on voice lifecycle:
  -- droneVibrato does not expose the synthetic freq/gate/velocity tags.
  { mpoFrequencyControl = Nothing
  , mpoGateControl      = Nothing
  , mpoVelocityControl  = Nothing
  }

midiFreqTag :: ControlTag
midiFreqTag =
  ControlTag (MigrationKey "carrier") 0

midiGateTag :: ControlTag
midiGateTag =
  ControlTag (MigrationKey "envelope") 0

midiVelocityTag :: ControlTag
midiVelocityTag =
  ControlTag (MigrationKey "velocity") 0

midiLevelTag :: ControlTag
midiLevelTag =
  ControlTag (MigrationKey "lpf") 0

------------------------------------------------------------
-- Session MIDI listener adapter
--
-- This is the decoded-event worker above the MIDI producer adapter.
-- It only enqueues into SessionFanInHost; live PortMIDI device
-- ownership remains outside this module.
------------------------------------------------------------

sessionMIDIListenerTests :: TestTree
sessionMIDIListenerTests =
  testGroup "Session MIDI listener adapter"
  [ testCase "bracket cleanup: body return tears down blocked source" $ do
      entered <- newEmptyMVar
      events <- newEmptyMVar
      let source = MIDIS.MIDIListenerSource $ do
            putMVar entered ()
            takeMVar events
      result <- timeout 1000000 $
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListener
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \_listener ->
                    timeout 1000000 (takeMVar entered)
      case result of
        Nothing ->
          assertFailure "MIDI listener teardown hung on blocked source"
        Just (Left issue) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Just ())) ->
          pure ()
        Just (Right Nothing) ->
          assertFailure "timed out waiting for MIDI source read"

  , testCase "source end-of-input exits worker without changing body result" $ do
      events <- newIORef
        [ Just (MIDIProducerNoteOn 0 69 100)
        , Nothing
        ]
      eofSeen <- newEmptyMVar
      producerResult <- newEmptyMVar
      let source = MIDIS.MIDIListenerSource $ do
            remaining <- readIORef events
            case remaining of
              [] -> do
                putMVar eofSeen ()
                pure Nothing
              next : rest -> do
                writeIORef events rest
                case next of
                  Nothing ->
                    putMVar eofSeen ()
                  Just _ ->
                    pure ()
                pure next
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResult
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    mResult <- timeout 1000000 (takeMVar producerResult)
                    mEof <- timeout 1000000 (takeMVar eofSeen)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mResult, mEof, state, snapshot, 42 :: Int)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [enq]), Just (),
               state, snapshot, value) -> do
          _queued <- fanInQueuedOrFail enq
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 1
          value @?= 42
        Right other ->
          assertFailure ("expected note-on followed by source EOF, got: "
                         <> show other)

  , testCase "producer rejection reports issue and listener continues" $ do
      events <- newEmptyMVar
      issues <- newEmptyMVar
      validResult <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult =
                \case
                  result@MIDIProducerEnqueueAttempted {} ->
                    putMVar validResult result
                  MIDIProducerRejected {} ->
                    pure ()
            , MIDIS.smlhOnIssue =
                putMVar issues
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 16 60 1))
                    mIssue <- timeout 1000000 (takeMVar issues)
                    putMVar events (Just (MIDIProducerNoteOn 0 69 127))
                    mResult <- timeout 1000000 (takeMVar validResult)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, mResult, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, Just (MIDIProducerEnqueueAttempted batch [enq]),
               state, snapshot) -> do
          issue @?= MIDIS.SmliProducerRejected (MpiInvalidChannel 16)
          queued <- fanInQueuedOrFail enq
          mpcbCommands batch @?= [qscCommand queued]
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected rejection then valid MIDI enqueue, got: "
                         <> show other)

  , testCase "listener state follows note-on and note-off sequence" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mOn <- timeout 1000000 (takeMVar producerResults)
                    stateAfterOn <- MIDIS.readSessionMIDIListenerState listener
                    putMVar events (Just (MIDIProducerNoteOff 0 69 0))
                    mOff <- timeout 1000000 (takeMVar producerResults)
                    stateAfterOff <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mOn, stateAfterOn, mOff, stateAfterOff, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [onEnq]),
               stateAfterOn,
               Just (MIDIProducerEnqueueAttempted _ [offEnq]),
               stateAfterOff,
               snapshot) -> do
          onQueued <- fanInQueuedOrFail onEnq
          offQueued <- fanInQueuedOrFail offEnq
          qscCommand onQueued
            @?= CmdVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "m0-69")
                  [ (midiFreqTag, 440.0)
                  , (midiGateTag, 1.0)
                  , (midiVelocityTag, 100.0 / 127.0)
                  ]
          qscCommand offQueued @?= CmdVoiceOff (VoiceKey "m0-69")
          mpsActiveNotes stateAfterOn
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          mpsActiveNotes stateAfterOff @?= M.empty
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure ("expected note-on/note-off listener results, got: "
                         <> show other)

  , testCase "listener state follows all-notes-off" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mOn <- timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mAllNotesOff <- timeout 1000000
                                      (takeMVar producerResults)
                    stateAfterAllNotesOff <-
                      MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mOn, mAllNotesOff, stateAfterAllNotesOff, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [onEnq]),
               Just (MIDIProducerEnqueueAttempted offBatch [offEnq]),
               stateAfterAllNotesOff,
               snapshot) -> do
          onQueued <- fanInQueuedOrFail onEnq
          offQueued <- fanInQueuedOrFail offEnq
          qscCommand onQueued
            @?= CmdVoiceOn
                  (TemplateName "drone")
                  (VoiceKey "m0-69")
                  [ (midiFreqTag, 440.0)
                  , (midiGateTag, 1.0)
                  , (midiVelocityTag, 100.0 / 127.0)
                  ]
          mpcbCommands offBatch @?= [CmdVoiceOff (VoiceKey "m0-69")]
          qscCommand offQueued @?= CmdVoiceOff (VoiceKey "m0-69")
          mpsActiveNotes stateAfterAllNotesOff @?= M.empty
          sfisQueueDepth snapshot @?= 2
        Right other ->
          assertFailure
            ("expected note-on/all-notes-off listener results, got: "
             <> show other)

  , testCase "listener coalesces pitch-bend writes until all-notes-off fence" $ do
      let activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          pitchValues =
            [9000..9008] :: [Word16]
          -- Last accepted value after the coalescing window.
          finalValue =
            9008 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral finalValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedFlush =
            [ CmdControlWrite (midiVoiceKey 0 note) midiFreqTag
                (expectedFreq note)
            | note <- [48..63]
            ]
          expectedFence =
            [ CmdVoiceOff (midiVoiceKey 0 note)
            | note <- [48..63]
            ]
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    pitchResults <- forM pitchValues $ \value -> do
                      putMVar events (Just (MIDIProducerPitchBend 0 value))
                      timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mFence <- timeout 1000000 (takeMVar producerResults)
                    stats <- MIDIS.readSessionMIDIListenerCoalescingStats
                               listener
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (pitchResults, mFence, stats, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (pitchResults,
               Just (MIDIProducerEnqueueAttempted fenceBatch fenceEnqueues),
               stats, state, snapshot) ->
          case sequence pitchResults of
            Nothing ->
              assertFailure "timed out waiting for coalesced pitch-bend events"
            Just results -> do
              forM_ results $ \case
                MIDIProducerEnqueueAttempted batch [] ->
                  length (mpcbCommands batch) @?= 16
                other ->
                  assertFailure
                    ("expected deferred pitch-bend result, got: "
                     <> show other)
              mpcbCommands fenceBatch @?= expectedFlush <> expectedFence
              length fenceEnqueues @?= 32
              map sfierQueueDepth fenceEnqueues @?= [1..32]
              sfisQueueDepth snapshot @?= 32
              mpsActiveNotes state @?= M.empty
              MIDIS.smlcsCoalescedCount stats @?= 128
              MIDIS.smlcsFlushedCount stats @?= 16
              MIDIS.smlcsBarrierFlushCount stats @?= 1
              MIDIS.smlcsPendingCount stats @?= 0
        Right other ->
          assertFailure
            ("expected coalesced pitch-bend flush at all-notes-off fence, got: "
             <> show other)

  , testCase "listener reports dropped fence when coalesced flush is rejected" $ do
      let activeNotes =
            M.fromList
              [ ((0, note), midiVoiceKey 0 note)
              | note <- [48..63]
              ]
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          stateAfterPitch =
            initialState { mpsPitchBends = M.singleton 0 pitchValue }
          fanInOpts =
            defaultSessionFanInOptions
              { sfioQueueOptions = SessionQueueOptions 8
              }
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq note =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedFlush =
            [ CmdControlWrite (midiVoiceKey 0 note) midiFreqTag
                (expectedFreq note)
            | note <- [48..63]
            ]
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      fenceIssues <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue =
                \case
                  issue@(MIDIS.SmliFenceDroppedForFlushFailure _ _) ->
                    putMVar fenceIssues issue
                  _ ->
                    pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          fanInOpts
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    putMVar events
                      (Just (MIDIProducerPitchBend 0 pitchValue))
                    mPitch <- timeout 1000000 (takeMVar producerResults)
                    putMVar events (Just (MIDIProducerAllNotesOff Nothing))
                    mFence <- timeout 1000000 (takeMVar producerResults)
                    mIssue <- timeout 1000000 (takeMVar fenceIssues)
                    stats <- MIDIS.readSessionMIDIListenerCoalescingStats
                               listener
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInHost host
                    pure (mPitch, mFence, mIssue, stats, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted pitchBatch []),
               Just (MIDIProducerEnqueueAttempted fenceBatch fenceEnqueues),
               Just fenceIssue, stats, state, snapshot) -> do
          length (mpcbCommands pitchBatch) @?= 16
          mpcbCommands fenceBatch @?= expectedFlush
          mpcbState fenceBatch @?= stateAfterPitch
          length fenceEnqueues @?= 16
          map sfierQueueDepth fenceEnqueues @?= [1..8] <> replicate 8 8
          let accepted =
                [ queued
                | result' <- map sfierResult fenceEnqueues
                , SessionEnqueued queued <- [result']
                ]
              rejected =
                [ issue'
                | result' <- map sfierResult fenceEnqueues
                , SessionEnqueueRejected _ _ issue' <- [result']
                ]
          map qscCommand accepted @?= take 8 expectedFlush
          rejected @?= replicate 8 (SeiQueueFull 8)
          fenceIssue
            @?= MIDIS.SmliFenceDroppedForFlushFailure
                  (MIDIProducerAllNotesOff Nothing)
                  8
          sfisQueueDepth snapshot @?= 8
          mpsActiveNotes state @?= activeNotes
          mpsPitchBends state @?= M.singleton 0 pitchValue
          MIDIS.smlcsCoalescedCount stats @?= 0
          MIDIS.smlcsFlushedCount stats @?= 8
          MIDIS.smlcsBarrierFlushCount stats @?= 1
          MIDIS.smlcsPendingCount stats @?= 16
        Right other ->
          assertFailure
            ("expected rejected coalesced flush to drop fence visibly, got: "
             <> show other)

  , testCase "listener flushes pending controls during teardown" $ do
      let note =
            60
          activeNotes =
            M.singleton (0, note) (midiVoiceKey 0 note)
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Nothing
              }
          expectedFreq =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedCommand =
            CmdControlWrite (midiVoiceKey 0 note) midiFreqTag expectedFreq
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              mPitch <-
                MIDIS.withSessionMIDIListenerHooksAndOptions
                  hooks
                  listenerOpts
                  testMIDIProducerOptions
                  initialState
                  source
                  host
                  $ \_listener -> do
                      putMVar events
                        (Just (MIDIProducerPitchBend 0 pitchValue))
                      timeout 1000000 (takeMVar producerResults)
              drained <- drainSessionFanInHost host
              pure (mPitch, drained)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch []), drained) -> do
          mpcbCommands batch @?= [expectedCommand]
          map (qscCommand . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [expectedCommand]
          sdrStopped (sfidrDrain drained) @?= Nothing
          sfidrQueueDepth drained @?= 0
        Right other ->
          assertFailure
            ("expected deferred pitch-bend flushed at teardown, got: "
             <> show other)

  , testCase "listener timed flush drains pending controls without a fence" $ do
      let note =
            60
          activeNotes =
            M.singleton (0, note) (midiVoiceKey 0 note)
          initialState =
            testMIDIProducerState activeNotes
          pitchValue =
            9000 :: Word16
          listenerOpts =
            MIDIS.defaultSessionMIDIListenerOptions
              { MIDIS.smloTimedControlFlushUsec = Just 1000
              }
          expectedFreq =
            midiNoteFrequency note
              * (2.0 ** ((((fromIntegral pitchValue - 8192.0) / 8192.0) * 2.0)
                          / 12.0))
          expectedCommand =
            CmdControlWrite (midiVoiceKey 0 note) midiFreqTag expectedFreq
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooksAndOptions
                hooks
                listenerOpts
                testMIDIProducerOptions
                initialState
                source
                host
                $ \listener -> do
                    putMVar events
                      (Just (MIDIProducerPitchBend 0 pitchValue))
                    mPitch <- timeout 1000000 (takeMVar producerResults)
                    (stats, snapshot) <-
                      waitForTimedControlFlush listener host
                    drained <- drainSessionFanInHost host
                    pure (mPitch, stats, snapshot, drained)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch []),
               stats, snapshot, drained) -> do
          mpcbCommands batch @?= [expectedCommand]
          sfisQueueDepth snapshot @?= 1
          map (qscCommand . sdiQueued) (sdrItems (sfidrDrain drained))
            @?= [expectedCommand]
          MIDIS.smlcsCoalescedCount stats @?= 0
          MIDIS.smlcsFlushedCount stats @?= 1
          MIDIS.smlcsBarrierFlushCount stats @?= 0
          MIDIS.smlcsPendingCount stats @?= 0
        Right other ->
          assertFailure
            ("expected timed flush of deferred pitch-bend, got: "
             <> show other)

  , testCase "queue-full rejection does not advance listener state" $ do
      let fanInOpts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
      events <- newEmptyMVar
      issues <- newEmptyMVar
      producerResults <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = putMVar issues
            }
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          fanInOpts
          $ \host -> do
              _prefill <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefill
                  host
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 127))
                    mResult <- timeout 1000000 (takeMVar producerResults)
                    mIssue <- timeout 1000000 (takeMVar issues)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    pure (mResult, mIssue, state)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted batch [enq]),
               Just issue, state) -> do
          mpcbState batch @?= initialMIDIProducerState
          mpsActiveNotes state @?= M.empty
          case mpcbCommands batch of
            [command] -> do
              sfierResult enq
                @?= SessionEnqueueRejected
                      (midiProducerId testMIDIProducerOptions)
                      command
                      (SeiQueueFull 1)
              issue @?= MIDIS.SmliEnqueueRejected command (SeiQueueFull 1)
            other ->
              assertFailure ("expected one MIDI command, got: " <> show other)
        Right other ->
          assertFailure ("expected queue-full listener result, got: "
                         <> show other)

  , testCase "bracket cleanup kills worker when producer hook blocks" $ do
      events <- newEmptyMVar
      hookEntered <- newEmptyMVar
      neverRelease <- newEmptyMVar
      let source = midiMVarSource events
          hooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult =
                \_result -> do
                  putMVar hookEntered ()
                  takeMVar neverRelease
            , MIDIS.smlhOnIssue =
                \_ -> pure ()
            }
      result <- timeout 1000000 $
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              MIDIS.withSessionMIDIListenerHooks
                hooks
                testMIDIProducerOptions
                initialMIDIProducerState
                source
                host
                $ \_listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    timeout 1000000 (takeMVar hookEntered)
      case result of
        Nothing ->
          assertFailure "MIDI listener teardown hung while hook was blocked"
        Just (Left issue) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Just ())) ->
          pure ()
        Just (Right Nothing) ->
          assertFailure "timed out waiting for blocking MIDI hook"

  , testCase "service host wakes worker for listener note-on" $ do
      events <- newEmptyMVar
      producerResults <- newEmptyMVar
      drainedVar <- newEmptyMVar
      let source = midiMVarSource events
          listenerHooks = MIDIS.SessionMIDIListenerHooks
            { MIDIS.smlhOnProducerResult = putMVar producerResults
            , MIDIS.smlhOnIssue          = \_ -> pure ()
            }
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service ->
              MIDIS.withSessionMIDIListenerHooks
                listenerHooks
                testMIDIPlayableOptions
                initialMIDIProducerState
                source
                (sessionFanInServiceHost service)
                $ \listener -> do
                    putMVar events (Just (MIDIProducerNoteOn 0 69 100))
                    mProducer <- timeout 1000000 (takeMVar producerResults)
                    mDrain <- timeout 1000000 (takeMVar drainedVar)
                    state <- MIDIS.readSessionMIDIListenerState listener
                    snapshot <- readSessionFanInService service
                    pure (mProducer, mDrain, state, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (Just (MIDIProducerEnqueueAttempted _ [enq]),
               Just drained, state, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected listener note-on to commit through service, got: "
                 <> show other)
          mpsActiveNotes state
            @?= M.singleton (0, 69) (VoiceKey "m0-69")
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected MIDI listener voice after service drain"
            (M.member (VoiceKey "m0-69") (ssVoices (sfisOwnerState snapshot)))
        Right other ->
          assertFailure ("expected MIDI listener service enqueue, got: "
                         <> show other)
  ]

midiMVarSource :: MVar (Maybe MIDIProducerEvent) -> MIDIS.MIDIListenerSource
midiMVarSource events =
  MIDIS.MIDIListenerSource (takeMVar events)

waitForTimedControlFlush
  :: MIDIS.SessionMIDIListener
  -> SessionFanInHost
  -> IO (MIDIS.SessionMIDIListenerCoalescingStats, SessionFanInSnapshot)
waitForTimedControlFlush listener host =
  loop (100 :: Int)
  where
    loop 0 =
      assertFailure "timed out waiting for MIDI listener timed control flush"
    loop n = do
      stats <- MIDIS.readSessionMIDIListenerCoalescingStats listener
      snapshot <- readSessionFanInHost host
      if MIDIS.smlcsPendingCount stats == 0 && sfisQueueDepth snapshot > 0
         then pure (stats, snapshot)
         else do
           threadDelay 1000
           loop (n - 1)

------------------------------------------------------------
-- Session MIDI PortMIDI source
--
-- This is the hardware-backed source boundary for the decoded MIDI
-- listener. Tests use an invalid device id so they stay deterministic
-- on no-controller and headless CI hosts.
------------------------------------------------------------

sessionMIDIPortMIDISourceTests :: TestTree
sessionMIDIPortMIDISourceTests =
  testGroup "Session MIDI PortMIDI source"
  [ testCase "event tags match the C ABI header contract" $
      MIDIPM.portMIDISourceEventKindTags @?= (0, 1, 2, 3, 4)

  , testCase "invalid device opens an idle closeable source" $ do
      result <-
        MIDIPM.withPortMIDISource invalidPortMIDIOptions $ \case
          Nothing ->
            pure (Left "source open returned Nothing")
          Just source -> do
            hasDevice <- MIDIPM.portMIDISourceHasDevice source
            mEvent <- MIDIPM.pollPortMIDISourceEvent source
            pure (Right (hasDevice, mEvent))
      case result of
        Left err ->
          assertFailure err
        Right (hasDevice, mEvent) -> do
          hasDevice @?= False
          mEvent @?= Nothing

  , testCase "idle PortMIDI source composes with MIDI listener teardown" $ do
      result <- timeout 1000000 $
        MIDIPM.withPortMIDISource invalidPortMIDIOptions $ \case
          Nothing ->
            pure (Left "source open returned Nothing")
          Just source ->
            Right <$>
              withSessionFanInHost
                (patternTemplates droneVibrato)
                defaultSessionFanInOptions
                (\host ->
                   MIDIS.withSessionMIDIListener
                     testMIDIProducerOptions
                     initialMIDIProducerState
                     (MIDIPM.portMIDIListenerSource invalidPortMIDIOptions
                                                    source)
                     host
                     $ \_listener -> pure (42 :: Int))
      case result of
        Nothing ->
          assertFailure "PortMIDI listener teardown hung on idle source"
        Just (Left err) ->
          assertFailure err
        Just (Right (Left issue)) ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Just (Right (Right value)) ->
          value @?= 42
  ]

invalidPortMIDIOptions :: MIDIPM.PortMIDISourceOptions
invalidPortMIDIOptions = MIDIPM.defaultPortMIDISourceOptions
  { MIDIPM.pmsoDeviceId      = Just 2147483647
  , MIDIPM.pmsoPollDelayUsec = 1000
  }

------------------------------------------------------------
-- Session UI producer adapter
--
-- This adapter is Haskell-only and consumes already-decoded UI
-- intents. It is not a GUI toolkit binding, manifest reload path, or
-- authorization layer.
------------------------------------------------------------

sessionUIProducerTests :: TestTree
sessionUIProducerTests =
  testGroup "Session UI producer adapter"
  [ testCase "decodes UI intents to session commands" $ do
      let start =
            UIVoiceOn
              (TemplateName "drone")
              (VoiceKey "u0")
              [(midiLevelTag, 0.5)]
          write =
            UIControlWrite (VoiceKey "u0") midiLevelTag 0.75
          stop =
            UIVoiceOff (VoiceKey "u0")
          swap =
            UIHotSwap
              (SwapLabel "ui-swap")
              (patternTemplates droneVibrato)
      decodeUISessionCommand start
        @?= Right (CmdVoiceOn
                    (TemplateName "drone")
                    (VoiceKey "u0")
                    [(midiLevelTag, 0.5)])
      decodeUISessionCommand write
        @?= Right (CmdControlWrite (VoiceKey "u0") midiLevelTag 0.75)
      decodeUISessionCommand stop
        @?= Right (CmdVoiceOff (VoiceKey "u0"))
      decodeUISessionCommand swap
        @?= Right (CmdHotSwap
                    (SwapLabel "ui-swap")
                    (patternTemplates droneVibrato))

  , testCase "rejects non-finite UI values before enqueue" $ do
      let infinity = 1.0 / 0.0
      decodeUISessionCommand
        (UIControlWrite (VoiceKey "u0") midiLevelTag infinity)
        @?= Left (UpiNonFiniteControlValue midiLevelTag infinity)
      decodeUISessionCommand
        (UIVoiceOn
          (TemplateName "drone")
          (VoiceKey "u0")
          [(midiLevelTag, infinity)])
        @?= Left (UpiNonFiniteInitialControl midiLevelTag infinity)

  , testCase "successful enqueue attributes command to ProducerUI" $ do
      let opts = testUIProducerOptions
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent opts intent host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          command @?= CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          producerKind (qscProducer queued) @?= ProducerUI
          producerName (qscProducer queued) @?= upoProducerName opts
          qscCommand queued @?= command
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected UI enqueue attempt, got: " <> show other)

  , testCase "decode rejection does not enqueue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") midiLevelTag infinity
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  defaultSessionFanInOptions
                  $ \host -> do
                    enq <- enqueueUIProducerIntent
                             testUIProducerOptions
                             intent
                             host
                    snapshot <- readSessionFanInHost host
                    pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerRejected issue, snapshot) -> do
          issue @?= UpiNonFiniteControlValue midiLevelTag infinity
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected UI rejection, got: " <> show other)

  , testCase "queue-full surfaces through UI enqueue result" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      result <- withSessionFanInHost
                  (patternTemplates droneVibrato)
                  opts
                  $ \host -> do
                    _prefill <-
                      enqueueSessionFanInCommand
                        (testProducer ProducerTest "prefill")
                        prefill
                        host
                    enqueueUIProducerIntent
                      testUIProducerOptions
                      intent
                      host
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (UIProducerEnqueueAttempted command enq) -> do
          command @?= expected
          sfierResult enq
            @?= SessionEnqueueRejected
                  (uiProducerId testUIProducerOptions)
                  expected
                  (SeiQueueFull 1)
        Right other ->
          assertFailure ("expected queue-full UI enqueue, got: " <> show other)

  , testCase "service host wakes worker for UI voice-on" $ do
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueUIProducerIntent
                       testUIProducerOptions
                       (UIVoiceOn (TemplateName "drone") (VoiceKey "u0") [])
                       (sessionFanInServiceHost service)
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (UIProducerEnqueueAttempted _ enq, Just drained, snapshot) -> do
          queued <- fanInQueuedOrFail enq
          map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
          case map sdiResult (sdrItems (sfidrDrain drained)) of
            [SessionOwnerStep (StepCommitted _ Nothing)] ->
              pure ()
            other ->
              assertFailure
                ("expected UI voice-on to commit through service, got: "
                 <> show other)
          sfisQueueDepth snapshot @?= 0
          assertBool
            "expected UI voice after service drain"
            (M.member (VoiceKey "u0") (ssVoices (sfisOwnerState snapshot)))
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for UI service drain"
        Right other ->
          assertFailure ("expected UI service enqueue, got: " <> show other)

  , testCase "arbitrated service UI enqueue defaults to FIFO" $ do
      let intent =
            UIVoiceOn (TemplateName "drone") (VoiceKey "u0") []
          expected =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "u0") []
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= uiProducerId testUIProducerOptions
            qscCommand queued @?= expected
            map sdiQueued (sdrItems (sfidrDrain drained)) @?= [queued]
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepCommitted _ Nothing)] ->
                pure ()
              other ->
                assertFailure
                  ("expected arbitrated UI voice-on to commit, got: "
                   <> show other)
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated UI service drain"
        Right other ->
          assertFailure ("expected arbitrated UI service enqueue, got: "
                         <> show other)

  , testCase "arbitrated service UI rejection reports service issue" $ do
      let intent =
            UIControlWrite (VoiceKey "u0") midiLevelTag 0.75
          expected =
            CmdControlWrite (VoiceKey "u0") midiLevelTag 0.75
          producer = uiProducerId testUIProducerOptions
          claimant = testProducer ProducerOSC "osc"
          target =
            ControlArbitrationTarget (VoiceKey "u0") midiLevelTag
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              enq <- enqueueArbitratedUIProducerIntent
                       testUIProducerOptions
                       intent
                       service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( UIProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (UIProducerArbitratedRejected issue, _mIssue, _mDrain, _snapshot) ->
          assertFailure ("expected arbitrated enqueue attempt, got local rejection: "
                         <> show issue)
        Right (_enq, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for UI arbitration rejection issue"
        Right (_enq, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("UI policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service UI decode rejection does not report issue" $ do
      let infinity = 1.0 / 0.0
          intent = UIControlWrite (VoiceKey "u0") midiLevelTag infinity
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <- enqueueArbitratedUIProducerIntent
                            testUIProducerOptions
                            intent
                            service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected
            @?= UIProducerArbitratedRejected
                  (UpiNonFiniteControlValue midiLevelTag infinity)
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("UI decode rejection unexpectedly reported service issue: "
             <> show issue)
  ]

testUIProducerOptions :: UIProducerOptions
testUIProducerOptions = defaultUIProducerOptions
  { upoProducerName = T.pack "ui-test"
  }

------------------------------------------------------------
-- Session OSC producer adapter
--
-- The adapter is intentionally narrow: it reuses the OSC dispatch
-- symbolic decoder, converts only control writes to SessionCommand,
-- and submits them to the generic fan-in host as ProducerOSC.
------------------------------------------------------------

sessionOSCProducerTests :: TestTree
sessionOSCProducerTests =
  testGroup "Session OSC producer adapter"
  [ testCase "decodes symbolic OSC control write to session command" $ do
      let msg = OSC.OscMessage (OBSC.pack "/v0/lpf/1")
                                [OSC.OscArgFloat 1800.0]
      decodeOSCSessionCommand msg
        @?= Right
              (CmdControlWrite
                (VoiceKey "v0")
                (ControlTag (MigrationKey "lpf") 1)
                1800.0)

  , testCase "valid control write enqueues under ProducerOSC" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgInt 700]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              700.0
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite opts msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted command enq, snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscProducer queued @?= producer
          qscCommand queued @?= expected
          sfierQueueDepth enq @?= 1
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected OSC enqueue attempt, got: " <> show other)

  , testCase "arbitrated service path defaults to FIFO behavior" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              enq <- enqueueArbitratedOSCControlWrite opts msg service
              mDrain <- timeout 1000000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (enq, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command gatewayResult
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (_enq, Nothing, _snapshot) ->
          assertFailure "timed out waiting for arbitrated OSC service drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC enqueue through service, got: "
             <> show other)

  , testCase "arbitrated service path reports policy rejection" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultOSCProducerOptions
          producer = oscProducerId opts
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
          msg = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1200.0]
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1200.0
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            , sfshOnIssue = putMVar issueVar
            }
          graph
          serviceOpts
          $ \service -> do
              rejected <- enqueueArbitratedOSCControlWrite opts msg service
              mIssue <- timeout 1000000 (takeMVar issueVar)
              mDrain <- timeout 100000 (takeMVar drainedVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( OSCProducerArbitratedEnqueueAttempted command rejected
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= SfsiiArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (_rejected, Nothing, _mDrain, _snapshot) ->
          assertFailure "timed out waiting for OSC arbitration issue"
        Right (_rejected, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC policy rejection unexpectedly woke service drain: "
             <> show extraDrain)

  , testCase "arbitrated service path decode rejection does not report issue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      issueVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnIssue = putMVar issueVar
            }
          graph
          defaultSessionFanInServiceOptions
          $ \service -> do
              rejected <-
                enqueueArbitratedOSCControlWrite
                  defaultOSCProducerOptions
                  msg
                  service
              mIssue <- timeout 100000 (takeMVar issueVar)
              snapshot <- readSessionFanInService service
              pure (rejected, mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (rejected, Nothing, snapshot) -> do
          rejected @?=
            OSCProducerArbitratedDecodeRejected
              (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right (_rejected, Just issue, _snapshot) ->
          assertFailure
            ("OSC decode rejection unexpectedly reported service issue: "
             <> show issue)

  , testCase "reserved and invalid identifiers are rejected" $ do
      let cases =
            [ ( "reserved voice"
              , OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiReservedPathSegment (OBSC.pack "swap")
              )
            , ( "invalid voice"
              , OSC.OscMessage (OBSC.pack "/bad name/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            , ( "invalid node tag"
              , OSC.OscMessage (OBSC.pack "/v0/bad name/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "bad slots and argument shapes are rejected" $ do
      let cases =
            [ ( "non-integer slot"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiSlotNotInteger (OBSC.pack "cutoff")
              )
            , ( "zero args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0") []
              , OSC.DiUnsupportedArgShape 0
              )
            , ( "two args"
              , OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                [OSC.OscArgFloat 1.0, OSC.OscArgInt 2]
              , OSC.DiUnsupportedArgShape 2
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case decodeOSCSessionCommand msg of
          Left issue ->
            issue @?= expected
          Right command ->
            assertFailure
              (label <> ": expected decode rejection, got "
               <> show command)

  , testCase "decode rejection does not enqueue" $ do
      let graph = patternTemplates droneVibrato
          msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      result <- withSessionFanInHost graph defaultSessionFanInOptions $
        \host -> do
          enq <- enqueueOSCControlWrite defaultOSCProducerOptions msg host
          snapshot <- readSessionFanInHost host
          pure (enq, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (enq, snapshot) -> do
          enq @?= OSCProducerDecodeRejected
                    (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0

  , testCase "queue-full surfaces through fan-in enqueue result" $ do
      let graph = patternTemplates droneVibrato
          opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          producer = oscProducerId defaultOSCProducerOptions
          msg0 = OSC.OscMessage (OBSC.pack "/v0/lpf/0")
                                 [OSC.OscArgFloat 800.0]
          msg1 = OSC.OscMessage (OBSC.pack "/v1/lpf/0")
                                 [OSC.OscArgFloat 900.0]
          cmd1 =
            CmdControlWrite
              (VoiceKey "v1")
              (ControlTag (MigrationKey "lpf") 0)
              900.0
      result <- withSessionFanInHost graph opts $ \host -> do
        enq0 <- enqueueOSCControlWrite defaultOSCProducerOptions msg0 host
        enq1 <- enqueueOSCControlWrite defaultOSCProducerOptions msg1 host
        snapshot <- readSessionFanInHost host
        pure (enq0, enq1, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (OSCProducerEnqueueAttempted _ first, second, snapshot) -> do
          _queued <- fanInQueuedOrFail first
          second
            @?= OSCProducerEnqueueAttempted
                  cmd1
                  SessionFanInEnqueueResult
                    { sfierResult =
                        SessionEnqueueRejected
                          producer
                          cmd1
                          (SeiQueueFull 1)
                    , sfierQueueDepth = 1
                    }
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full OSC enqueue, got: "
                         <> show other)
  ]

------------------------------------------------------------
-- Session OSC listener adapter
--
-- This is the UDP wrapper above the OSC producer adapter. It only
-- enqueues into SessionFanInHost; draining stays caller-driven.
------------------------------------------------------------

sessionOSCListenerTests :: TestTree
sessionOSCListenerTests =
  testGroup "Session OSC listener adapter"
  [ testCase "bracket cleanup: body return tears down listener" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host ->
              OSCS.withSessionOSCListener
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                (\_info -> pure (42 :: Int))
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right value ->
          value @?= 42

  , testCase "loopback packet enqueues but does not drain" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = putMVar received
                    , OSCS.solhOnIssue          = \_ -> pure ()
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    snapshot <- readSessionFanInHost host
                    pure (mResult, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (OSCProducerEnqueueAttempted command enq), snapshot) -> do
          command @?= expected
          queued <- fanInQueuedOrFail enq
          qscCommand queued @?= expected
          producerKind (qscProducer queued) @?= ProducerOSC
          sfisQueueDepth snapshot @?= 1
          sfisOwnerStatus snapshot @?= SessionOwnerReady
          ssVoices (sfisOwnerState snapshot) @?= M.empty
        Right other ->
          assertFailure ("expected one OSC producer result, got: "
                         <> show other)

  , testCase "arbitrated service listener loopback defaults to FIFO" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              received <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = \_ -> pure ()
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mDrain <- timeout 1000000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command gatewayResult)
          , Just drained
          , snapshot
          ) -> do
            command @?= expected
            queued <- gatewayQueuedOrFail gatewayResult
            qscProducer queued @?= producer
            qscCommand queued @?= expected
            case map sdiResult (sdrItems (sfidrDrain drained)) of
              [SessionOwnerStep (StepRejected (SiStaleVoice (VoiceKey "v0")))] ->
                pure ()
              other ->
                assertFailure
                  ("expected stale OSC control-write drain, got: "
                   <> show other)
            sfidrQueueDepth drained @?= 0
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener drain"
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener enqueue, got: "
             <> show other)

  , testCase "arbitrated service listener reports policy rejection" $ do
      let expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
          producer = oscProducerId defaultOSCProducerOptions
          claimant = testProducer ProducerUI "ui"
          target =
            ControlArbitrationTarget
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
          serviceOpts = defaultSessionFanInServiceOptions
            { sfsoArbitrationGatewayOptions =
                Just defaultSessionArbitrationGatewayOptions
                  { sagoInitialPolicy =
                      TargetClaim
                        (claimControlTarget target claimant emptyTargetClaimTable)
                  }
            }
          expectedIssue = ArbitrationIssue
            { aiProducer  = producer
            , aiCommand   = expected
            , aiTarget    = Just target
            , aiReason    = ArrTargetClaimedBy claimant
            , aiRetryable = False
            }
      drainedVar <- newEmptyMVar
      result <-
        withSessionFanInServiceHooks
          defaultSessionFanInServiceHooks
            { sfshOnDrain = putMVar drainedVar
            }
          (patternTemplates droneVibrato)
          serviceOpts
          $ \service -> do
              received <- newEmptyMVar
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult = putMVar received
                    , OSCS.solahOnIssue          = putMVar issues
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mResult <- timeout 1000000 (takeMVar received)
                    mIssue <- timeout 1000000 (takeMVar issues)
                    mDrain <- timeout 100000 (takeMVar drainedVar)
                    snapshot <- readSessionFanInService service
                    pure (mResult, mIssue, mDrain, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right
          ( Just (OSCProducerArbitratedEnqueueAttempted command rejected)
          , Just reported
          , Nothing
          , snapshot
          ) -> do
            command @?= expected
            rejected @?= SagArbitrationRejected expectedIssue
            reported @?= OSCS.SoliArbitrationRejected expectedIssue
            sfisQueueDepth snapshot @?= 0
        Right (Nothing, _mIssue, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener result"
        Right (_mResult, Nothing, _mDrain, _snapshot) ->
          assertFailure
            "timed out waiting for arbitrated OSC listener issue"
        Right (_mResult, Just _reported, Just extraDrain, _snapshot) ->
          assertFailure
            ("OSC listener policy rejection unexpectedly woke service drain: "
             <> show extraDrain)
        Right other ->
          assertFailure
            ("expected arbitrated OSC listener policy rejection, got: "
             <> show other)

  , testCase "arbitrated listener parse issue continues" $ do
      result <-
        withSessionFanInService
          (patternTemplates droneVibrato)
          defaultSessionFanInServiceOptions
          $ \service -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCArbitratedListenerHooks
                    { OSCS.solahOnProducerResult =
                        \result -> case result of
                          OSCProducerArbitratedEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerArbitratedDecodeRejected {} ->
                            pure ()
                    , OSCS.solahOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withArbitratedSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                service
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in service, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure
            ("valid packet was not accepted after malformed one: "
             <> show other)

  , testCase "malformed packet surfaces parse issue; listener continues" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newIORef []
              validDone <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult =
                        \result -> case result of
                          OSCProducerEnqueueAttempted {} ->
                            putMVar validDone ()
                          OSCProducerDecodeRejected {} ->
                            pure ()
                    , OSCS.solhOnIssue =
                        \issue -> modifyIORef' issues (issue :)
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback (OSCS.liBoundPort info)
                                    (OBS.pack [0x01, 0x02, 0x03, 0x04])
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mDone <- timeout 1000000 (takeMVar validDone)
                    issueList <- readIORef issues
                    pure (mDone, issueList)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just (), issueList) ->
          assertBool
            ("expected parse failure issue, got: " <> show issueList)
            (any isSessionParseFailure issueList)
        Right other ->
          assertFailure ("valid packet was not accepted after malformed one: "
                         <> show other)

  , testCase "decode rejection reports issue and does not enqueue" $ do
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          defaultSessionFanInOptions
          $ \host -> do
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesSwapLpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue
            @?= OSCS.SoliDecodeFailure
                  (OSC.DiReservedPathSegment (OBSC.pack "swap"))
          sfisQueueDepth snapshot @?= 0
        Right other ->
          assertFailure ("expected decode issue, got: " <> show other)

  , testCase "queue-full surfaces as listener issue" $ do
      let opts = defaultSessionFanInOptions
            { sfioQueueOptions = SessionQueueOptions 1
            }
          prefill =
            CmdVoiceOn (TemplateName "drone") (VoiceKey "already") []
          expected =
            CmdControlWrite
              (VoiceKey "v0")
              (ControlTag (MigrationKey "lpf") 0)
              1500.0
      result <-
        withSessionFanInHost
          (patternTemplates droneVibrato)
          opts
          $ \host -> do
              _prefillResult <-
                enqueueSessionFanInCommand
                  (testProducer ProducerTest "prefill")
                  prefill
                  host
              issues <- newEmptyMVar
              let hooks = OSCS.SessionOSCListenerHooks
                    { OSCS.solhOnProducerResult = \_ -> pure ()
                    , OSCS.solhOnIssue          = putMVar issues
                    }
              OSCS.withSessionOSCListenerHooks
                hooks
                defaultOSCProducerOptions
                host
                (OSCS.defaultListenerConfig 0)
                $ \info -> do
                    sendUdpLoopback
                      (OSCS.liBoundPort info)
                      messageBytesV0LpfFloat
                    mIssue <- timeout 1000000 (takeMVar issues)
                    snapshot <- readSessionFanInHost host
                    pure (mIssue, snapshot)
      case result of
        Left issue ->
          assertFailure ("expected fan-in host, got: " <> show issue)
        Right (Just issue, snapshot) -> do
          issue @?= OSCS.SoliEnqueueRejected expected (SeiQueueFull 1)
          sfisQueueDepth snapshot @?= 1
        Right other ->
          assertFailure ("expected queue-full listener issue, got: "
                         <> show other)
  ]
  where
    isSessionParseFailure (OSCS.SoliParseFailure _) = True
    isSessionParseFailure _                         = False

compileTemplateGraphOrFail :: [(String, SynthGraph)] -> IO TemplateGraph
compileTemplateGraphOrFail entries =
  case compileTemplateGraph entries of
    Left err ->
      assertFailure ("expected TemplateGraph, got: " <> err)
    Right tg ->
      pure tg

missingVoiceEvents :: Int -> [(SamplePos, PatternEvent)]
missingVoiceEvents n =
  missingVoiceEventsAt [0 .. n - 1]

missingVoiceEventsAt :: [Int] -> [(SamplePos, PatternEvent)]
missingVoiceEventsAt positions =
  [ ( SamplePos pos
    , PEVoiceOn (TemplateName "missing") (VoiceKey ("v" <> show pos)) []
    )
  | pos <- positions
  ]
