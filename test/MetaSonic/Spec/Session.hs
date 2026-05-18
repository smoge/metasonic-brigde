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
