{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.App.ManifestPreflightEvent
-- Description : Structured operator-visible event stream for the
--               resolver-stage preflight that runs before any
--               manifest reload strategy is invoked.
--
-- 'MetaSonic.App.ManifestReloadEvent' covers the strategy timeline
-- once a preserving or stopped-audio route has been chosen. The
-- transitions before that — catalog lookup, manifest target
-- resolution, plan compile/diagnostic — are not part of that
-- family. Resolver-stage failures in
-- 'MetaSonic.App.ManifestLiveSession.runReloadWithSink' short-circuit
-- before the supervisor is invoked, so a 'ManifestReloadEvent'
-- consumer never sees them.
--
-- 'ManifestPreflightEvent' is the per-transition timeline that wraps
-- the resolver call. Each constructor names one boundary the resolver
-- crossed; the rejection payload carries a structured
-- 'PreflightRejectionReason' so consumers can distinguish a catalog
-- miss (the demo key was not in the loaded catalog) from a plan
-- diagnostic (the catalog resolved but the planner refused the
-- demo). The event family is intentionally small in v1: it covers
-- the resolver stage only and does not bracket the orchestrator-
-- stage @hproPreparePlan@ / @hsaroPreparePlan@ failures, which keep
-- surfacing as in-phase 'MrePreservingReloadRejected' /
-- 'MreStoppedAudioReloadRejected' events.
--
-- v1 has no callback seam. The timeline is built and rendered
-- inline inside 'runReloadWithSink' (via 'renderPreflightEvents' in
-- 'MetaSonic.App.ManifestLiveCommon'); there is no @mrhcOnEvent@
-- analogue threaded through the resolver because no current
-- consumer subscribes asynchronously. The 'ReloadResolver' itself
-- now returns @Either PreflightRejectionReason plan@ — callers that
-- were relying on the prior @Either String plan@ shape must adapt
-- (the live-shell production resolver and the test stubs are the
-- only call sites today). If a later consumer needs an opt-in
-- callback seam analogous to
-- 'MetaSonic.App.ManifestReloadEvent.noManifestReloadEvents', wire
-- it then alongside the consumer rather than speculatively now.

module MetaSonic.App.ManifestPreflightEvent
  ( ManifestPreflightEvent (..)
  , PreflightRejectionReason (..)
  ) where

-- | One operator-visible transition in a resolver-stage preflight
-- run.
--
--   * 'MpeStarted' brackets every run and carries the requested key
--     the operator typed (or its programmatic equivalent).
--   * 'MpeRejected' fires when the resolver returned 'Left'. The
--     payload distinguishes catalog miss from plan rejection so
--     downstream renderers can label the failure precisely.
--   * 'MpeSucceeded' fires when the resolver returned 'Right'. The
--     supervisor will run next; the strategy lifecycle in
--     'MetaSonic.App.ManifestReloadEvent' picks up from there.
--
-- Exactly one of 'MpeRejected' / 'MpeSucceeded' fires per run,
-- always after a single 'MpeStarted'. Consumers can rely on that
-- bracket invariant.
data ManifestPreflightEvent
  = MpeStarted !String
      -- ^ Requested reload key.
  | MpeRejected !String !PreflightRejectionReason
      -- ^ Requested reload key and the structured rejection reason.
  | MpeSucceeded !String
      -- ^ Requested reload key whose plan resolved successfully.
  deriving stock (Eq, Show)

-- | Structured rejection reason for the resolver-stage preflight.
--
-- The 'catalogPlanResolver' production resolver in
-- 'MetaSonic.App.ManifestLiveSession' raises two structurally
-- distinct failures:
--
--   * @no demo named …@ when the catalog lookup misses, before any
--     planner runs;
--   * the rendered @ManifestReloadCliIssue@ string when
--     'planManifestReloadForDemo' refused the demo.
--
-- Carrying that distinction in the event lets a renderer surface
-- "catalog miss" separately from "plan diagnostic" without parsing
-- the rejection string.
data PreflightRejectionReason
  = MprrCatalogMissed
      -- ^ The requested key was not in the loaded catalog. No
      -- planner was invoked.
  | MprrPlanRejected !String
      -- ^ The catalog resolved but the planner refused the demo.
      -- The payload is the rendered diagnostic text, treated as
      -- opaque by this event family.
  deriving stock (Eq, Show)
