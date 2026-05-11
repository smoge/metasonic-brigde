-- |
-- Module      : MetaSonic.App.Osc
-- Description : Phase 6.B.4 — thin @--osc-listen@ CLI wrapper.
--
-- A small front-end for the library entry point
-- 'MetaSonic.OSC.Listen.withOscListener'. Loads a built-in demo
-- graph ('SinOsc 440 Hz → tagged "outgain" Gain → Out 0'),
-- registers a single voice key @v0@ against the auto-spawned
-- slot 0, starts the realtime audio stream, runs the listener,
-- and blocks on Enter to stop.
--
-- The same shape as the §3 MIDI demo and the existing
-- @--audio-only@ path, but the live event source is OSC over UDP
-- instead of MIDI from hardware. No new realtime ABI; the
-- listener writes through @rt_graph_realtime_set_control@.

module MetaSonic.App.Osc
  ( runOscListen
  ) where

import           Control.Exception           (finally)
import qualified Data.ByteString.Char8       as BSC
import           Data.IORef                  (newIORef)
import           Foreign.Ptr                 (Ptr)
import           System.Exit                 (die)
import           System.IO                   (hPutStrLn, stderr)

import           MetaSonic.Bridge.Compile    (rgNodes)
import           MetaSonic.Bridge.FFI        (RTGraph, loadTemplateGraph,
                                              startAudio, stopAudio,
                                              waitAudioStarted, withRTGraph)
import           MetaSonic.Bridge.Source     (SynthGraph, gain, out, runSynth,
                                              sinOsc, tagged)
import           MetaSonic.Bridge.Templates  (Template (..), TemplateGraph (..),
                                              compileTemplateGraph)
import qualified MetaSonic.OSC.Dispatch      as OSC
import qualified MetaSonic.OSC.Listen        as OSC

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

-- Mirrors Main.hs's audio constants; copied rather than imported
-- because Main.hs's @demoMaxFrames@ / @demoOutputChannels@ are
-- module-private. Keeping them in step is a documentation
-- problem (Note [Audio constants]), not a load-bearing
-- invariant.
oscMaxFrames :: Int
oscMaxFrames = 256

oscOutputChannels :: Int
oscOutputChannels = 2

oscDeviceID :: Int
oscDeviceID = -1   -- runtime infers from configured Out buses

oscReadyTimeoutMs :: Int
oscReadyTimeoutMs = 1000

----------------------------------------------------------------------
-- Built-in demo graph
----------------------------------------------------------------------

-- A 440 Hz sine through a scalar gain (tagged @outgain@) to
-- hardware bus 0. The default gain is 0.5; OSC packets of the
-- form @/v0/outgain/0 ,f <amount>@ change the gain in real
-- time. Same shape as the §6.B.3 end-to-end test graph so the
-- CLI exercises the verified path.
listenDemoGraph :: SynthGraph
listenDemoGraph = runSynth $ do
  o <- sinOsc 440.0 0.0
  g <- tagged "outgain" (gain o 0.5)
  out 0 g

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

-- | Run the OSC listener demo on the given UDP port. Loads the
-- built-in demo graph, starts realtime audio, runs the listener
-- in the background, and blocks on Enter to stop.
--
-- Bind address is @0.0.0.0@ (any interface). For loopback-only
-- testing, the caller can change 'lcBindHost' through the
-- library API directly — the CLI does not expose it as a flag
-- yet.
runOscListen :: Int -> IO ()
runOscListen port = do
  putStrLn "OSC listener demo."
  putStrLn ""
  putStrLn "  graph: SinOsc 440 Hz -> tagged \"outgain\" Gain -> Out 0"
  putStrLn "  voice: v0 (slot 0, template \"default\")"
  putStrLn ""
  putStrLn "  Send OSC packets to localhost:<bound port> to control the gain:"
  putStrLn "      /v0/outgain/0 ,f <amount>          # set gain in [0, 1]"
  putStrLn ""

  tg <- case compileTemplateGraph [("default", listenDemoGraph)] of
    Right t   -> pure t
    Left  err -> die $ "OSC listen demo: compile failed: " <> err

  let totalNodes =
        sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

  withRTGraph totalNodes oscMaxFrames $ \rt -> do
    loadTemplateGraph rt tg

    rs0 <-
      case OSC.registerVoice (BSC.pack "v0") 0 (BSC.pack "default")
             (OSC.emptyResolveState tg) of
        Right rs  -> pure rs
        Left  iss -> die $ "OSC listen demo: registerVoice: " <> show iss
    rsRef <- newIORef rs0

    let cfg =
          (OSC.defaultListenerConfig port)
            { OSC.lcBindHost = "0.0.0.0" }
        hooks =
          (OSC.defaultListenerHooks rt)
            { OSC.lhOnIssue = \iss ->
                hPutStrLn stderr ("  OSC drop: " <> show iss)
            }

    OSC.withOscListenerHooks hooks rsRef cfg $ \info -> do
      putStrLn $ "  Listening on UDP port " <> show (OSC.liBoundPort info) <> "."
      runOscAudioBracket rt

-- Same start/wait/stop dance as Main.hs's 'runRealtimeBracket',
-- duplicated here so the OSC subcommand does not pull in
-- Main.hs's module-private audio constants. Worth deduplicating
-- only if a third caller appears.
runOscAudioBracket :: Ptr RTGraph -> IO ()
runOscAudioBracket rt = do
  putStrLn "  Starting realtime audio..."
  startRC <- startAudio rt oscOutputChannels oscDeviceID
  if startRC /= 0
    then putStrLn $ "  Audio start failed with status " <> show startRC
    else flip finally (stopAudio rt) $ do
      ready <- waitAudioStarted rt oscReadyTimeoutMs
      if ready
        then do
          putStrLn "  Press Enter to stop."
          _ <- getLine
          pure ()
        else
          putStrLn $
            "  Audio stream opened, but the callback did not report "
            <> "ready within " <> show oscReadyTimeoutMs <> " ms."
