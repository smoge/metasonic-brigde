{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestReloadAudioEvent
-- Description : Structured operator-visible event stream for the
--               audio-stage boundaries of a stopped-audio manifest
--               reload.
--
-- 'MetaSonic.App.ManifestReloadEvent' collapses every transition
-- between 'MreStoppedAudioReloadStarted' and the terminal
-- 'MreStoppedAudioReloadCommitted' / 'MreStoppedAudioReloadRejected'
-- into one boundary. An operator who sees
-- @stopped-audio phase rejected: audio-restart-failed
-- (start-failed 12)@ cannot tell from the strategy timeline whether
-- the failure was on the @stopAudio@ side (which would mean the
-- old owner never released the device) or on the @startAudio@ side
-- (which would mean the new owner is installed but its audio never
-- came up). Both are real operator concerns with different recovery
-- shapes.
--
-- 'ManifestReloadAudioEvent' is the per-boundary timeline that
-- wraps the audio-side calls inside the stopped-audio orchestrator.
-- The constructors bracket the two audible side-effects
-- ('hsaroStopOldAudio' and 'hsaroStartNewAudio') with explicit
-- attempt/succeeded/failed transitions; on the listener-restart
-- failure path the cleanup @hsaroStopNewAudio@ also fires a
-- bracketed pair so an operator can see the rollback.
--
-- Preserving reloads do not stop audio and produce no audio events
-- — consumers should treat an empty timeline as "preserving path or
-- audio never reached" rather than "stopped-audio path succeeded".
-- The reload-strategy timeline in
-- 'MetaSonic.App.ManifestReloadEvent' remains the source of truth
-- for which strategy ran and how it terminated.
--
-- v1 has no separate ready-wait surface: the ready-wait failure
-- mode @SfaiReadyTimeout@ surfaces inside 'MraeStartFailed', not as
-- a distinct event. Splitting it out would require plumbing a
-- callback through 'startSessionFanInHostAudioWith', which is out
-- of scope for this slice. The design note in
-- @notes/2026-05-25-b-allocation-resource-recovery-event-semantics.md@
-- documents the slice-2 follow-up.
--
-- v1 covers stopped-audio only. The preserving path's hot-swap
-- never stops audio, so the preserving variant of the orchestrator
-- does not take an audio-event callback. Tests should pin
-- "preserving emits no audio events" rather than treat the empty
-- timeline as an implementation accident; slice 2 will make that
-- contract explicit when it also covers the recovery path's audio
-- restart inside @sopsOpenStack@.

module MetaSonic.App.ManifestReloadAudioEvent
  ( ManifestReloadAudioEvent (..)
  , noManifestReloadAudioEvents
  ) where

-- | One operator-visible boundary in the audio-stage of a
-- stopped-audio reload.
--
-- The expected timeline for a successful stopped-audio reload is
-- @[MraeStopAttempted, MraeStopSucceeded, MraeStartAttempted,
-- MraeStartSucceeded]@. A failure of @hsaroStopOldAudio@ truncates
-- the timeline at @MraeStopFailed@; a failure of @hsaroStartNewAudio@
-- truncates it at @MraeStartFailed@ — the strategy-level
-- 'HsariStopOldAudioFailed' / 'HsariAudioRestartFailed' carries the
-- same payload one layer up.
--
-- On the listener-restart-failed cleanup path
-- ('HsariListenerRestartFailed'), the orchestrator's
-- @hsaroStopNewAudio@ fires a final @[MraeStopAttempted,
-- MraeStopSucceeded]@ pair. Cleanup failures are silent at the
-- 'IO ()' level (@hsaroStopNewAudio :: IO ()@), so v1 does not emit
-- @MraeStopFailed@ for the cleanup; a future slice can split the
-- cleanup into its own constructors if a real consumer needs that
-- distinction.
--
-- The @issue@ parameter matches the orchestrator's
-- 'HostStoppedAudioReloadOps' issue type — the same wrapped
-- shape that lands in the @Hsari*@ outcome constructors. In
-- production the live session resolves it to
-- @ManifestReloadHostIssue LiveProdIngressIssue@ (so the
-- failure payload reads the same as the strategy-level
-- 'HsariStopOldAudioFailed' / 'HsariAudioRestartFailed' values
-- one layer up). Tests are free to instantiate the issue
-- parameter to a simpler type to keep fixtures terse; the design
-- note's "fan-in @SessionFanInAudioIssue@" framing remains true
-- one layer below — by the time the issue reaches the
-- orchestrator it has already been wrapped through
-- @MrhiAudio@.
data ManifestReloadAudioEvent issue
  = MraeStopAttempted
      -- ^ About to call an audio-stop side effect. Brackets
      -- @hsaroStopOldAudio@ on the main path, and
      -- @hsaroStopNewAudio@ on the listener-restart cleanup path.
  | MraeStopSucceeded
      -- ^ The audio-stop call returned cleanly.
  | MraeStopFailed !issue
      -- ^ The audio-stop call returned 'Left'. Carries the same
      -- issue value the strategy timeline will surface as
      -- 'HsariStopOldAudioFailed'.
  | MraeStartAttempted
      -- ^ About to call @hsaroStartNewAudio@.
  | MraeStartSucceeded
      -- ^ @hsaroStartNewAudio@ returned 'Right ()'. The new owner's
      -- audio is running.
  | MraeStartFailed !issue
      -- ^ @hsaroStartNewAudio@ returned 'Left'. Carries the same
      -- issue value the strategy timeline will surface as
      -- 'HsariAudioRestartFailed'.
  deriving stock (Eq, Show)

-- | Drop-in no-op callback for entrypoints that do not subscribe to
-- audio events. Mirrors
-- 'MetaSonic.App.ManifestReloadEvent.noManifestReloadEvents'.
noManifestReloadAudioEvents :: ManifestReloadAudioEvent issue -> IO ()
noManifestReloadAudioEvents _ = pure ()
