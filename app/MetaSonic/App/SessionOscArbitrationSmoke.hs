{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : MetaSonic.App.SessionOscArbitrationSmoke
-- Description : Manual smoke runner for OSC session arbitration.
--
-- This is a repeatable manual probe for the explicit session-layer OSC
-- arbitration path:
--
-- @
-- OSC UDP -> Session.OSCListener -> Session.OSCProducer -> FanInService
-- @
--
-- It deliberately does not start realtime audio and does not replace
-- the older @--osc-listen@ direct realtime demo.

module MetaSonic.App.SessionOscArbitrationSmoke
  ( runSessionOscArbitrationSmoke
  ) where

import           Control.Concurrent              (threadDelay)
import           Control.Monad                   (when)
import           Data.IORef                      (modifyIORef', newIORef,
                                                  readIORef)
import           Data.Text                       (pack)
import           System.Exit                     (die)
import           System.IO                       (hFlush, hPutStrLn, stderr,
                                                  stdout)

import           MetaSonic.Bridge.Source         (MigrationKey (..),
                                                  SynthGraph, gain, lpf, out,
                                                  runSynth, sinOsc, tagged)
import           MetaSonic.Bridge.Templates      (compileTemplateGraph)
import           MetaSonic.Pattern               (ControlTag (..),
                                                  VoiceKey (..))
import           MetaSonic.Session.Arbitration   (ArbitrationPolicy (..),
                                                  ControlArbitrationTarget (..),
                                                  claimControlTarget,
                                                  emptyTargetClaimTable)
import           MetaSonic.Session.ArbitrationGateway
                                                 (SessionArbitrationGatewayEnqueueResult (..),
                                                  defaultSessionArbitrationGatewayOptions,
                                                  sagoInitialPolicy)
import           MetaSonic.Session.FanIn         (sfidrDrain,
                                                  sfidrQueueDepth,
                                                  sfierQueueDepth,
                                                  sfierResult,
                                                  sfisQueueDepth)
import           MetaSonic.Session.FanInService  (SessionFanInServiceHooks (..),
                                                  SessionFanInServiceIssue (..),
                                                  defaultSessionFanInServiceHooks,
                                                  defaultSessionFanInServiceOptions,
                                                  readSessionFanInService,
                                                  sfsoArbitrationGatewayOptions,
                                                  withSessionFanInServiceHooks)
import qualified MetaSonic.Session.OSCListener   as OSCS
import           MetaSonic.Session.OSCProducer   (OSCProducerArbitratedEnqueueResult (..),
                                                  defaultOSCProducerOptions)
import           MetaSonic.Session.Queue         (ProducerId (..),
                                                  ProducerKind (..),
                                                  sdrItems, sdrStopped)

-- | Run a bounded manual smoke test over the session OSC arbitration
-- stack. The command exits non-zero when no OSC packets are observed or
-- when the configured target-claim policy is not exercised.
runSessionOscArbitrationSmoke :: Int -> Int -> IO ()
runSessionOscArbitrationSmoke seconds port = do
  graph <- case compileTemplateGraph [("voice", sessionOscSmokeGraph)] of
    Right tg -> pure tg
    Left err -> die $ "Session OSC arbitration smoke graph failed: " <> err

  let target =
        ControlArbitrationTarget
          (VoiceKey "v0")
          (ControlTag (MigrationKey "lpf") 0)
      claimant = ProducerId ProducerUI (pack "session-osc-smoke-claim")
      serviceOpts = defaultSessionFanInServiceOptions
        { sfsoArbitrationGatewayOptions =
            Just defaultSessionArbitrationGatewayOptions
              { sagoInitialPolicy =
                  TargetClaim
                    (claimControlTarget target claimant emptyTargetClaimTable)
              }
        }

  putStrLn "Session OSC arbitration smoke."
  putStrLn ""
  putStrLn "  path: OSC UDP -> Session.OSCListener -> FanInService"
  putStrLn "  graph: tagged lpf voice template"
  putStrLn $
    "  policy: TargetClaim " <> show target <> " claimed by "
    <> show claimant
  putStrLn $ "  window: " <> show seconds <> " second(s)"
  putStrLn $
    "  note: allowed writes may drain as SiStaleVoice; this probe "
    <> "does not spawn audio voices."
  putStrLn ""
  hFlush stdout

  producerEvents <- newIORef (0 :: Int)
  listenerIssues <- newIORef (0 :: Int)
  listenerArbitration <- newIORef (0 :: Int)
  serviceIssues <- newIORef (0 :: Int)
  serviceArbitration <- newIORef (0 :: Int)
  drainedItems <- newIORef (0 :: Int)

  let serviceHooks =
        defaultSessionFanInServiceHooks
          { sfshOnDrain = \drained -> do
              let n = length (sdrItems (sfidrDrain drained))
              modifyIORef' drainedItems (+ n)
              when (n > 0) $
                putStrLn $
                  "  drain: items=" <> show n
                  <> " queue_depth=" <> show (sfidrQueueDepth drained)
                  <> " stopped=" <> show (sdrStopped (sfidrDrain drained))
          , sfshOnIssue = \issue ->
              case issue of
                SfsiiArbitrationRejected arbIssue -> do
                  modifyIORef' serviceArbitration (+ 1)
                  hPutStrLn stderr $
                    "  service arbitration rejected: " <> show arbIssue
                _ -> do
                  modifyIORef' serviceIssues (+ 1)
                  hPutStrLn stderr ("  service issue: " <> show issue)
          }
      listenerHooks =
        OSCS.defaultSessionOSCArbitratedListenerHooks
          { OSCS.solahOnProducerResult = \result -> do
              modifyIORef' producerEvents (+ 1)
              putStrLn ("  producer: " <> summarizeProducerResult result)
          , OSCS.solahOnIssue = \issue ->
              case issue of
                OSCS.SoliArbitrationRejected arbIssue -> do
                  modifyIORef' listenerArbitration (+ 1)
                  hPutStrLn stderr $
                    "  listener arbitration rejected: " <> show arbIssue
                _ -> do
                  modifyIORef' listenerIssues (+ 1)
                  hPutStrLn stderr ("  listener issue: " <> show issue)
          }

  result <-
    withSessionFanInServiceHooks serviceHooks graph serviceOpts $ \service ->
      OSCS.withArbitratedSessionOSCListenerHooks
        listenerHooks
        defaultOSCProducerOptions
        service
        (OSCS.defaultListenerConfig port)
        $ \info -> do
            putStrLn $
              "  Listening on UDP port "
              <> show (OSCS.liBoundPort info)
              <> "."
            putStrLn "  Send claimed target for arbitration rejection:"
            putStrLn $
              "      tools/send_osc.py --port "
              <> show (OSCS.liBoundPort info)
              <> " --address /v0/lpf/0 --value 1200"
            putStrLn "  Send unclaimed target for normal fan-in drain:"
            putStrLn $
              "      tools/send_osc.py --port "
              <> show (OSCS.liBoundPort info)
              <> " --address /v1/lpf/0 --value 1200"
            putStrLn ""
            hFlush stdout
            threadDelay (seconds * 1000000)
            threadDelay 50000
            snapshot <- readSessionFanInService service
            observed <- readIORef producerEvents
            lIssues <- readIORef listenerIssues
            lArb <- readIORef listenerArbitration
            sIssues <- readIORef serviceIssues
            sArb <- readIORef serviceArbitration
            drained <- readIORef drainedItems
            pure (observed, lIssues, lArb, sIssues, sArb, drained, snapshot)

  case result of
    Left issue ->
      dieAfterFlush $
        "Session fan-in service setup failed: " <> show issue
    Right (observed, lIssues, lArb, sIssues, sArb, drained, snapshot) -> do
      putStrLn ""
      putStrLn $
        "  observed_events=" <> show observed
        <> " listener_issues=" <> show lIssues
        <> " listener_arbitration_rejections=" <> show lArb
        <> " service_issues=" <> show sIssues
        <> " service_arbitration_rejections=" <> show sArb
        <> " drained_items=" <> show drained
      putStrLn $
        "  queue_depth=" <> show (sfisQueueDepth snapshot)
      putStrLn $
        "  arbitration_counter_match=" <> show (lArb == sArb)
      when (observed == 0) $
        dieAfterFlush
          "No supported OSC packets observed during smoke window."
      when (lArb == 0 && sArb == 0) $
        dieAfterFlush $
          "No arbitration rejections observed. Send the claimed "
          <> "/v0/lpf/0 target during the smoke window."
      when (lArb /= sArb) $
        dieAfterFlush $
          "Listener/service arbitration rejection counters diverged: "
          <> "listener=" <> show lArb
          <> " service=" <> show sArb
          <> ". Both hooks should observe the same policy rejections."
      putStrLn "Session OSC arbitration smoke complete."

sessionOscSmokeGraph :: SynthGraph
sessionOscSmokeGraph = runSynth $ do
  osc <- sinOsc 220.0 0.0
  filt <- tagged "lpf" (lpf osc 800.0 0.8)
  amp <- gain filt 0.25
  out 0 amp

summarizeProducerResult :: OSCProducerArbitratedEnqueueResult -> String
summarizeProducerResult = \case
  OSCProducerArbitratedDecodeRejected issue ->
    "decode_rejected " <> show issue
  OSCProducerArbitratedEnqueueAttempted command gatewayResult ->
    case gatewayResult of
      SagArbitrationRejected issue ->
        "arbitration_rejected command=" <> show command
        <> " issue=" <> show issue
      SagEnqueueAttempted enqueueResult ->
        "enqueue_attempted command=" <> show command
        <> " result=" <> show (sfierResult enqueueResult)
        <> " queue_depth=" <> show (sfierQueueDepth enqueueResult)

dieAfterFlush :: String -> IO ()
dieAfterFlush msg = do
  hFlush stdout
  hFlush stderr
  die msg
