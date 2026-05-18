{-# LANGUAGE LambdaCase #-}

-- | Session Prep L: preserving hot-swap semantics tests.
--
-- Prep K is a decision gate, not an implementation. These tests pin
-- the execution-time semantics that preserving implementations must
-- preserve. Unsupported preserving shapes still reject in the real
-- RTGraph adapter; the one preserved-voice missing-control case uses
-- a mock adapter ('constantAdapter' + a resolver-shaped adapter) to
-- model a successful preserve path with a stripped post-swap control
-- surface.
module MetaSonic.Spec.Session.PreservingHotSwap
  ( sessionPreservingHotSwapSpecTests
  ) where

import qualified Data.Map.Strict                    as M

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source            (Connection (..),
                                                     MigrationKey (..), out,
                                                     runSynth, sinOsc, tagged)
import           MetaSonic.ControlTarget            (ControlTargetIssue (..),
                                                     resolveControlTarget)
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Session.Command          (SessionIssue (..),
                                                     fromPatternEvent)
import           MetaSonic.Session.Owner
import           MetaSonic.Session.Queue
import           MetaSonic.Session.Resolve
import           MetaSonic.Session.Runtime
import           MetaSonic.Session.State
import           MetaSonic.Session.Step
import           MetaSonic.Spec.SessionShared       (compileTemplateGraphOrFail,
                                                     constantAdapter,
                                                     enqueueOrFail, queueOrFail,
                                                     testProducer)

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
