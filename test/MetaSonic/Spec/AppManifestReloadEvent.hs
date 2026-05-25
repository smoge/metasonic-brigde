{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : MetaSonic.Spec.AppManifestReloadEvent
-- Description : Focused event-order coverage for the manifest
--               reload operator event stream.
--
-- These tests exercise the orchestrator-level @-WithEvents@
-- variants directly against hand-built 'HostPreservingReloadOps' /
-- 'HostStoppedAudioReloadOps' fakes, plus the strategy-level
-- pure-core helper 'runReloadHostStrategyWithEvents' against
-- pre-bound preserving / stopped-audio actions. The point is to
-- pin the event order on the timeline, not to exercise the real
-- session-layer plumbing — the existing
-- "MetaSonic.Spec.AppManifestReloadHost" suite covers the
-- IO-realistic side.

module MetaSonic.Spec.AppManifestReloadEvent
  ( appManifestReloadEventTests
  ) where

import           Data.IORef                       (IORef, modifyIORef', newIORef,
                                                   readIORef)

import           Test.Tasty                       (TestTree, testGroup)
import           Test.Tasty.HUnit                 (testCase, (@?=))

import           MetaSonic.App.ManifestReloadEvent
                                                  (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadHost
                                                  (ManifestReloadHostIssue (..),
                                                   ManifestReloadHostStrategy (..),
                                                   ManifestReloadHostStrategyIssue (..),
                                                   ManifestReloadHostStrategyRan (..),
                                                   runReloadHostStrategyWithEvents)
import           MetaSonic.App.ManifestReloadOrchestration
                                                  (HostPreservingDrainFailure (..),
                                                   HostPreservingReloadFailure (..),
                                                   HostPreservingReloadIssue (..),
                                                   HostPreservingReloadOps (..),
                                                   HostStoppedAudioDrainFailure (..),
                                                   HostStoppedAudioReloadFailure (..),
                                                   HostStoppedAudioReloadIssue (..),
                                                   HostStoppedAudioReloadOps (..),
                                                   orchestrateHostPreservingReloadWithEvents,
                                                   orchestrateHostStoppedAudioReloadWithEvents)
import           MetaSonic.Pattern                (TemplateName (..),
                                                   VoiceKey (..))
import           MetaSonic.Session.Resolve        (RetiredVoiceBinding (..),
                                                   RetiredVoiceReason (..),
                                                   VoiceBinding (..))

------------------------------------------------------------
-- Event capture
------------------------------------------------------------

-- | The orchestrator emits events at issue @String@; that keeps the
-- test fixtures lightweight (no real @ManifestReloadHostIssue@ needed
-- at the orchestrator seam) while still exercising the structured
-- payloads on the rejection constructors.
type TestEvent = ManifestReloadEvent String

newEventLog :: IO (IORef [TestEvent], TestEvent -> IO ())
newEventLog = do
  ref <- newIORef []
  pure (ref, \e -> modifyIORef' ref (e :))

readEvents :: IORef [TestEvent] -> IO [TestEvent]
readEvents = fmap reverse . readIORef

-- | Strategy-level tests use the host issue parameter directly. Same
-- pattern, but the rejection payloads are typed.
type StrategyEvent = ManifestReloadEvent (ManifestReloadHostIssue String)

newStrategyEventLog
  :: IO (IORef [StrategyEvent], StrategyEvent -> IO ())
newStrategyEventLog = do
  ref <- newIORef []
  pure (ref, \e -> modifyIORef' ref (e :))

readStrategyEvents :: IORef [StrategyEvent] -> IO [StrategyEvent]
readStrategyEvents = fmap reverse . readIORef

------------------------------------------------------------
-- Preserving Ops fakes
------------------------------------------------------------

-- | All-success preserving ops. Each slot returns 'Right'; tests
-- override individual slots to force specific failure paths.
preservingOpsAllSuccess :: HostPreservingReloadOps () () String
preservingOpsAllSuccess =
  HostPreservingReloadOps
    { hproPreparePlan      = \_ -> pure (Right ())
    , hproQuiesceIngress   = pure (Right ())
    , hproDrainLive        = pure (Right ())
    , hproReloadPreserving = \_ -> pure (Right [])
    , hproResumeService    = pure ()
    , hproResumeOldIngress = pure (Right ())
    , hproReopenIngress    = pure (Right ())
    }

------------------------------------------------------------
-- Stopped-audio Ops fakes
------------------------------------------------------------

-- | All-success stopped-audio ops. Same pattern as the preserving
-- helper above.
stoppedAudioOpsAllSuccess
  :: HostStoppedAudioReloadOps () () String
stoppedAudioOpsAllSuccess =
  HostStoppedAudioReloadOps
    { hsaroPreparePlan      = \_ -> pure (Right ())
    , hsaroQuiesceIngress   = pure (Right ())
    , hsaroDrainLive        = pure (Right ())
    , hsaroStopOldAudio     = pure (Right ())
    , hsaroReloadStopped    = \_ -> pure (Right [])
    , hsaroRestartOldAudio  = pure (Right ())
    , hsaroResumeOldIngress = pure (Right ())
    , hsaroStartNewAudio    = pure (Right ())
    , hsaroReopenIngress    = pure (Right ())
    , hsaroStopNewAudio     = pure ()
    }

------------------------------------------------------------
-- Test tree
------------------------------------------------------------

appManifestReloadEventTests :: TestTree
appManifestReloadEventTests =
  testGroup "App manifest reload event stream"
    [ testCase "preserving success: Started, Committed" $ do
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostPreservingReloadWithEvents
            onEvent
            preservingOpsAllSuccess
            ()
        result @?= Right ()
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MrePreservingReloadCommitted []
          ]

    , testCase "preserving success: MrePreservingReloadCommitted carries the retired-binding payload from hproReloadPreserving" $ do
        -- Phase 8h step 3e v1: the success arm of the preserving op
        -- now returns '[RetiredVoiceBinding]'; the orchestrator must
        -- forward that list verbatim onto the commit event so a
        -- downstream renderer can show which bindings did not migrate.
        (ref, onEvent) <- newEventLog
        let leadRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "lead/1") 0 (TemplateName "saw_lead"))
                RvrTemplateGone
            padRetired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "pad/A") 1 (TemplateName "sustain"))
                RvrTemplateGone
            ops = preservingOpsAllSuccess
              { hproReloadPreserving = \_ ->
                  pure (Right [leadRetired, padRetired])
              }
        result <-
          orchestrateHostPreservingReloadWithEvents
            onEvent
            ops
            ()
        result @?= Right ()
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MrePreservingReloadCommitted [leadRetired, padRetired]
          ]

    , testCase "preserving retryable rejection, resume success" $ do
        -- Drain fails retryably; resume-old-ingress succeeds.
        -- Expected timeline: Started, ResumeStarted, ResumeSucceeded,
        -- Rejected (with HpariDrainRejected).
        let ops = preservingOpsAllSuccess
              { hproDrainLive =
                  pure (Left (HprdfRetryable "drain-failed"))
              }
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostPreservingReloadWithEvents onEvent ops ()
        result @?= Left (HpariDrainRejected "drain-failed")
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MreResumeOldIngressStarted
          , MreResumeOldIngressSucceeded
          , MrePreservingReloadRejected (HpariDrainRejected "drain-failed")
          ]

    , testCase "preserving retryable rejection, resume failure" $ do
        -- Drain fails retryably; resume-old-ingress also fails.
        -- The final rejection becomes HpariDrainRejectedResumeFailed
        -- with both causes preserved; the timeline shows the resume
        -- attempt firing and failing before the phase rejection.
        let ops = preservingOpsAllSuccess
              { hproDrainLive =
                  pure (Left (HprdfRetryable "drain-failed"))
              , hproResumeOldIngress =
                  pure (Left "resume-failed")
              }
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostPreservingReloadWithEvents onEvent ops ()
        result @?=
          Left
            (HpariDrainRejectedResumeFailed
              "drain-failed"
              "resume-failed")
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MreResumeOldIngressStarted
          , MreResumeOldIngressFailed "resume-failed"
          , MrePreservingReloadRejected
              (HpariDrainRejectedResumeFailed
                "drain-failed"
                "resume-failed")
          ]

    , testCase "preserving reload-command enqueue rejected, resume success" $ do
        -- The preserving hot-swap command is rejected at the fan-in
        -- service before it runs (e.g. mid-reload-window). The
        -- timeline emits the new EnqueueRejected event between
        -- Started and the resume attempt; the final phase rejection
        -- still collapses to HpariReloadRejected so downstream
        -- fallback / supervisor policy is unchanged.
        let ops = preservingOpsAllSuccess
              { hproReloadPreserving = \_plan ->
                  pure (Left (HprfReloadEnqueueRejected "enqueue-rejected"))
              }
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostPreservingReloadWithEvents onEvent ops ()
        result @?= Left (HpariReloadRejected "enqueue-rejected")
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MrePreservingReloadEnqueueRejected "enqueue-rejected"
          , MreResumeOldIngressStarted
          , MreResumeOldIngressSucceeded
          , MrePreservingReloadRejected
              (HpariReloadRejected "enqueue-rejected")
          ]

    , testCase "preserving reload-command enqueue rejected, resume failure" $ do
        -- Same as above but resume-old-ingress also fails. The final
        -- rejection collapses to HpariReloadRejectedResumeFailed and
        -- the timeline names the resume failure between the new
        -- EnqueueRejected event and the phase rejection.
        let ops = preservingOpsAllSuccess
              { hproReloadPreserving = \_plan ->
                  pure (Left (HprfReloadEnqueueRejected "enqueue-rejected"))
              , hproResumeOldIngress =
                  pure (Left "resume-failed")
              }
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostPreservingReloadWithEvents onEvent ops ()
        result @?=
          Left
            (HpariReloadRejectedResumeFailed
              "enqueue-rejected"
              "resume-failed")
        events <- readEvents ref
        events @?=
          [ MrePreservingReloadStarted
          , MrePreservingReloadEnqueueRejected "enqueue-rejected"
          , MreResumeOldIngressStarted
          , MreResumeOldIngressFailed "resume-failed"
          , MrePreservingReloadRejected
              (HpariReloadRejectedResumeFailed
                "enqueue-rejected"
                "resume-failed")
          ]

    , testCase "stopped-audio success: Started, Committed" $ do
        (ref, onEvent) <- newEventLog
        result <-
          orchestrateHostStoppedAudioReloadWithEvents
            onEvent
            stoppedAudioOpsAllSuccess
            ()
        result @?= Right ()
        events <- readEvents ref
        events @?=
          [ MreStoppedAudioReloadStarted
          , MreStoppedAudioReloadCommitted []
          ]

    , testCase "stopped-audio success: MreStoppedAudioReloadCommitted carries the pre-release retired-voice snapshot" $ do
        -- Phase 8h step 3e v1: stopped-audio always retires every
        -- pre-reload binding (the old owner is released wholesale)
        -- with reason 'RvrOwnerReplaced'. The orchestrator forwards
        -- the list 'hsaroReloadStopped' returns; the real session
        -- layer snapshots it before 'releaseSessionOwner'.
        (ref, onEvent) <- newEventLog
        let v0Retired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v0") 0 (TemplateName "drone"))
                RvrOwnerReplaced
            v1Retired =
              RetiredVoiceBinding
                (VoiceBinding (VoiceKey "v1") 1 (TemplateName "drone"))
                RvrOwnerReplaced
            ops = stoppedAudioOpsAllSuccess
              { hsaroReloadStopped = \_ ->
                  pure (Right [v0Retired, v1Retired])
              }
        result <-
          orchestrateHostStoppedAudioReloadWithEvents
            onEvent
            ops
            ()
        result @?= Right ()
        events <- readEvents ref
        events @?=
          [ MreStoppedAudioReloadStarted
          , MreStoppedAudioReloadCommitted [v0Retired, v1Retired]
          ]

    , testCase "strategy fallback admitted: preserving HpariReloadRejected → stopped-audio committed" $ do
        -- Preserving rejects with HpariReloadRejected (the only
        -- preserving outcome that admits fallback per
        -- 'preservingAllowsStoppedAudioFallback'); stopped-audio
        -- succeeds. Expected timeline at the strategy seam:
        -- StrategyStarted, [preserving phase events],
        -- FallbackAdmitted, [stopped-audio phase events],
        -- StrategySucceeded MrhsrStoppedAudioAfterPreservingRejected.
        let preservingIssue   =
              HpariReloadRejected (MrhiIngress "reload-rejected")
            preservingAction  =
              pure (Left preservingIssue)
                :: IO (Either (HostPreservingReloadIssue
                                 (ManifestReloadHostIssue String))
                              ())
            stoppedAction     =
              pure (Right ())
                :: IO (Either (HostStoppedAudioReloadIssue
                                 (ManifestReloadHostIssue String))
                              ())
        (ref, onEvent) <- newStrategyEventLog
        result <-
          runReloadHostStrategyWithEvents
            onEvent
            TryPreservingThenStoppedAudio
            preservingAction
            stoppedAction
        result @?=
          Right (MrhsrStoppedAudioAfterPreservingRejected
                   preservingIssue)
        events <- readStrategyEvents ref
        events @?=
          [ MreStrategyStarted TryPreservingThenStoppedAudio
          , MreFallbackAdmitted preservingIssue
          , MreStrategySucceeded
              (MrhsrStoppedAudioAfterPreservingRejected
                preservingIssue)
          ]

    , testCase "strategy fallback declined: preserving HpariDrainFailedTerminal stays surfaced" $ do
        -- A terminal preserving failure does NOT admit fallback;
        -- the strategy emits FallbackDeclined and surfaces the
        -- preserving rejection directly. Expected timeline:
        -- StrategyStarted, [preserving phase events],
        -- FallbackDeclined, StrategyFailed (MrhsiPreservingFailed).
        let preservingIssue   =
              HpariDrainFailedTerminal (MrhiIngress "drain-terminal")
            preservingAction  =
              pure (Left preservingIssue)
                :: IO (Either (HostPreservingReloadIssue
                                 (ManifestReloadHostIssue String))
                              ())
            stoppedAction     =
              pure (Right ())
                :: IO (Either (HostStoppedAudioReloadIssue
                                 (ManifestReloadHostIssue String))
                              ())
        (ref, onEvent) <- newStrategyEventLog
        result <-
          runReloadHostStrategyWithEvents
            onEvent
            TryPreservingThenStoppedAudio
            preservingAction
            stoppedAction
        result @?=
          Left (MrhsiPreservingFailed preservingIssue)
        events <- readStrategyEvents ref
        events @?=
          [ MreStrategyStarted TryPreservingThenStoppedAudio
          , MreFallbackDeclined preservingIssue
          , MreStrategyFailed (MrhsiPreservingFailed preservingIssue)
          ]
    ]
