{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : MetaSonic.Spec.AppManifestLiveSessionOutputSink
-- Description : Tests for the Phase 8j output-sink plumbing.
--
-- Pins the structural property that closes the 8j TTY line-discipline
-- corruption: every operator-facing line in the live session must
-- route through an injectable @String -> IO ()@ sink, not directly
-- through 'putStrLn'. In production the live session swaps that sink
-- to Haskeline's 'getExternalPrint'-returned action while a command
-- loop is open, so async OSC output cannot corrupt the operator's
-- in-progress edit buffer.
--
-- These tests use IORef-collecting fake sinks to assert that the
-- listener-hook variants and the @*With@ print helpers honor the
-- sink. The actual visual redraw is Haskeline's contract and is
-- validated by the 8j post-fix live replay; this module covers the
-- plumbing.
module MetaSonic.Spec.AppManifestLiveSessionOutputSink
  ( appManifestLiveSessionOutputSinkTests
  ) where

import           Data.IORef       (IORef, newIORef, readIORef,
                                   modifyIORef', writeIORef)
import qualified Data.Text        as T

import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=), assertBool,
                                   assertFailure)

import           MetaSonic.App.ManifestLiveCommon
                                   (liveOSCListenerHooksWithControlsAndObserverAndOutput)
import           MetaSonic.App.ManifestOSCListener
                                   (ManifestOSCListenerHooks (..),
                                    ManifestOSCListenerIssue (..))
import           MetaSonic.App.ManifestReloadOSCBinding
                                   (ManifestOSCControlBinding (..))
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Pattern              (ControlTag (..),
                                                 VoiceKey (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInEnqueueResult (..))
import           MetaSonic.Session.OSCProducer  (OSCProducerEnqueueResult (..))
import           MetaSonic.Session.Queue        (CommandSequence (..),
                                                 ProducerId (..),
                                                 ProducerKind (..),
                                                 QueuedSessionCommand (..),
                                                 SessionEnqueueIssue (..),
                                                 SessionEnqueueResult (..))


appManifestLiveSessionOutputSinkTests :: TestTree
appManifestLiveSessionOutputSinkTests =
  testGroup "App manifest live-session output sink (Phase 8j)"
  [ testCase
      "accept-line routes through the supplied sink, not stdout" $ do
        sinkLog       <- newIORef []
        observerLog   <- newIORef []
        let hooks  =
              liveOSCListenerHooksWithControlsAndObserverAndOutput
                [cutoffBinding]
                (\v t val -> modifyIORef' observerLog (<> [(v, t, val)]))
                (recordSink sinkLog)
            cmd    = CmdControlWrite (vk "v0") cutoffTag 1800.0
            event  = acceptedResult cmd
        molhOnAccepted hooks event
        sinkLines <- readIORef sinkLog
        obsLines  <- readIORef observerLog
        case sinkLines of
          [line] -> do
            assertContains "osc accept" line
            assertContains "value=1800" line
          _ ->
            assertFailure ("expected one accept-line via sink, got: "
                           <> show sinkLines)
        obsLines @?= [(vk "v0", cutoffTag, 1800.0)]

  , testCase
      "issue-line routes through the supplied sink" $ do
        sinkLog <- newIORef []
        let hooks =
              liveOSCListenerHooksWithControlsAndObserverAndOutput
                [cutoffBinding]
                (\_ _ _ -> pure ())
                (recordSink sinkLog)
            issue =
              MoliParseFailure "bogus payload"
        molhOnIssue hooks issue
        sinkLines <- readIORef sinkLog
        case sinkLines of
          [line] -> do
            assertContains "osc reject (parse)" line
            assertContains "bogus payload" line
          _ ->
            assertFailure ("expected one issue-line via sink, got: "
                           <> show sinkLines)

  , testCase
      "rejected accepted-write does not invoke the cache observer but still routes nothing through the accept sink" $ do
        sinkLog     <- newIORef []
        observerLog <- newIORef []
        let hooks =
              liveOSCListenerHooksWithControlsAndObserverAndOutput
                [cutoffBinding]
                (\v t val -> modifyIORef' observerLog (<> [(v, t, val)]))
                (recordSink sinkLog)
            cmd   = CmdControlWrite (vk "v0") cutoffTag 1800.0
            event = rejectedResult cmd
        molhOnAccepted hooks event
        readIORef sinkLog     >>= (@?= [])
        readIORef observerLog >>= (@?= [])

  , testCase
      "sink swap (putStrLn → IORef-collecting) is observable via the same dyn closure used in production" $ do
        -- Mirrors how 'runManifestLiveSession' wires the listener hook:
        -- the hook captures a sink that reads from an IORef each call.
        -- Before the swap, output goes to the initial sink; after the
        -- swap it goes to the new sink. The hook closure is unchanged.
        initialSink <- newIORef []
        swappedSink <- newIORef []
        ref         <- newIORef (recordSink initialSink)
        let dynSink s = readIORef ref >>= ($ s)
            hooks    =
              liveOSCListenerHooksWithControlsAndObserverAndOutput
                [cutoffBinding]
                (\_ _ _ -> pure ())
                dynSink
            event    = acceptedResult (CmdControlWrite (vk "v0") cutoffTag 600.0)
        molhOnAccepted hooks event
        writeIORef ref (recordSink swappedSink)
        molhOnAccepted hooks event
        initialLines <- readIORef initialSink
        swappedLines <- readIORef swappedSink
        length initialLines @?= 1
        length swappedLines @?= 1
  ]
  where
    assertContains needle haystack =
      assertBool
        ("expected " <> show needle <> " in: " <> haystack)
        (T.pack needle `T.isInfixOf` T.pack haystack)


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

recordSink :: IORef [String] -> String -> IO ()
recordSink ref s = modifyIORef' ref (<> [s])


vk :: String -> VoiceKey
vk = VoiceKey

tag :: String -> Int -> ControlTag
tag node slot = ControlTag (MigrationKey node) slot

cutoffTag :: ControlTag
cutoffTag = tag "lpf" 0

cutoffBinding :: ManifestOSCControlBinding
cutoffBinding = ManifestOSCControlBinding
  { mocbControlTag  = cutoffTag
  , mocbDisplayName = "cutoff"
  , mocbDefault     = 600.0
  , mocbRangeMin    = 200.0
  , mocbRangeMax    = 6000.0
  , mocbCC          = Just 74
  }


-- Helpers for building OSCProducerEnqueueResult fixtures.
testProducer :: ProducerId
testProducer = ProducerId
  { producerKind = ProducerTest
  , producerName = T.pack "tty-line-discipline-test"
  }

acceptedResult :: SessionCommand -> OSCProducerEnqueueResult
acceptedResult cmd =
  OSCProducerEnqueueAttempted cmd SessionFanInEnqueueResult
    { sfierResult = SessionEnqueued QueuedSessionCommand
        { qscSequence = CommandSequence 1
        , qscProducer = testProducer
        , qscCommand  = cmd
        }
    , sfierQueueDepth = 1
    }

rejectedResult :: SessionCommand -> OSCProducerEnqueueResult
rejectedResult cmd =
  OSCProducerEnqueueAttempted cmd SessionFanInEnqueueResult
    { sfierResult =
        SessionEnqueueRejected testProducer cmd SeiReloadInProgress
    , sfierQueueDepth = 0
    }
