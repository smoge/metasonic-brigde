{-# LANGUAGE LambdaCase #-}

-- | Session command, runtime ownership, queue, host, UI, and OSC producer tests.
module MetaSonic.Spec.Session where

import qualified Data.Map.Strict           as M
import qualified Data.Text                 as T
import           Control.Concurrent        (forkIO, newEmptyMVar, putMVar,
                                            takeMVar)
import           Control.Monad             (forM_)
import           Data.IORef                (modifyIORef', newIORef, readIORef,
                                            writeIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.OSCProducer
import qualified MetaSonic.Session.OSCListener as OSCS
import           MetaSonic.Session.UIProducer
import           MetaSonic.Spec.Core
import           MetaSonic.Spec.SessionShared

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC

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
