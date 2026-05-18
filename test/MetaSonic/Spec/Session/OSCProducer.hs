-- | Session OSC producer adapter tests.
--
-- The adapter is intentionally narrow: it reuses the OSC dispatch
-- symbolic decoder, converts only control writes to SessionCommand,
-- and submits them to the generic fan-in host as ProducerOSC. Tests
-- cover decode rejection, raw + arbitrated host/service paths, and
-- queue-full surfacing. The UDP wrapper around this adapter lives in
-- "MetaSonic.Spec.Session.OSCListener".
module MetaSonic.Spec.Session.OSCProducer
  ( sessionOSCProducerTests
  ) where

import qualified Data.ByteString.Char8     as OBSC
import           Control.Concurrent        (newEmptyMVar, putMVar, takeMVar)
import           Control.Monad             (forM_)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (MigrationKey (..))
import qualified MetaSonic.OSC.Dispatch             as OSC
import qualified MetaSonic.OSC.Wire                 as OSC
import           MetaSonic.Pattern                  (ControlTag (..),
                                                     Pattern (..),
                                                     VoiceKey (..))
import           MetaSonic.Pattern.Corpus           (droneVibrato)
import           MetaSonic.Session.Arbitration
import           MetaSonic.Session.ArbitrationGateway
import           MetaSonic.Session.Command          (SessionCommand (..),
                                                     SessionIssue (..))
import           MetaSonic.Session.FanIn
import           MetaSonic.Session.FanInService
import           MetaSonic.Session.OSCProducer
import           MetaSonic.Session.Owner            (SessionOwnerStepResult (..))
import           MetaSonic.Session.Queue
import           MetaSonic.Session.Step             (SessionStepResult (..))
import           MetaSonic.Spec.SessionShared       (fanInQueuedOrFail,
                                                     gatewayQueuedOrFail,
                                                     testProducer)

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
