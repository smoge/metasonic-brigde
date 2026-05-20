-- | Output-regression coverage for the manifest live reload demo's
-- strategy-outcome renderer.
--
-- Pins F-1 from notes/2026-05-16-c: 'renderOutcome' previously used
-- 'show' on the full strategy result, which on a single failed
-- preserving install expanded to a multi-KB 'TemplateGraph' /
-- 'RuntimeNode' dump on one line.
--
-- The test exercises every 'HostPreservingReloadIssue' and
-- 'HostStoppedAudioReloadIssue' constructor with a payload string
-- that explicitly contains "TemplateGraph" and "RuntimeNode", and
-- asserts the rendered output never leaks those substrings — i.e.
-- the renderer never includes the carried issue in its output.
module MetaSonic.Spec.AppManifestLiveReloadDemoRender where

import           Data.List                              (isInfixOf)
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveReloadDemo   (LiveReloadRoute (..),
                                                         selectLiveReloadRoute)
import           MetaSonic.App.ManifestReloadCli        (renderHostPreservingIssueTag,
                                                         renderHostStoppedAudioIssueTag,
                                                         renderStrategyRan)
import           MetaSonic.App.ManifestReloadHost       (ManifestReloadHostStrategy (..),
                                                         ManifestReloadHostStrategyRan (..))
import           MetaSonic.App.ManifestReloadOrchestration
                                                        (HostPreservingReloadIssue (..),
                                                         HostStoppedAudioReloadIssue (..))


appManifestLiveReloadDemoRenderTests :: TestTree
appManifestLiveReloadDemoRenderTests =
  testGroup "App manifest live reload demo render"
  [ testCase "renderHostPreservingIssueTag never leaks the carried issue payload" $
      mapM_
        (\mkIssue ->
           assertNoLeak (renderHostPreservingIssueTag (mkIssue leakProbe)))
        allHpariConstructors

  , testCase "renderHostStoppedAudioIssueTag never leaks the carried issue payload" $
      mapM_
        (\mkIssue ->
           assertNoLeak (renderHostStoppedAudioIssueTag (mkIssue leakProbe)))
        allHsariConstructors

  , testCase "renderStrategyRan MrhsrPreserving is short and free of dump substrings" $ do
      let line = renderStrategyRan (MrhsrPreserving :: ManifestReloadHostStrategyRan String)
      assertNoLeak line
      assertShortLine 200 line

  , testCase "renderStrategyRan MrhsrStoppedAudio is short and free of dump substrings" $ do
      let line = renderStrategyRan (MrhsrStoppedAudio :: ManifestReloadHostStrategyRan String)
      assertNoLeak line
      assertShortLine 200 line

  , testCase "renderStrategyRan MrhsrStoppedAudioAfterPreservingRejected does not leak payload" $ do
      let ran :: ManifestReloadHostStrategyRan String
          ran = MrhsrStoppedAudioAfterPreservingRejected
                  (HpariReloadRejected leakProbe)
          line = renderStrategyRan ran
      assertNoLeak line
      assertShortLine 300 line

    -- §219 slice 4 routing: the audible
    -- @--manifest-live-reload-demo@ now dispatches the
    -- 'StoppedAudioOnly' strategy through the supervised
    -- lifecycle (factory + adapter + 'reloadSupervised').
    -- Preserving and TryPreservingThenStoppedAudio stay on the
    -- direct path while the supervised stopped-audio route
    -- accumulates hardware exercise.
    --
    -- 'selectLiveReloadRoute' is a pure selector. Pinning each
    -- strategy's route here catches a class of regressions
    -- where a refactor silently changes which strategies use
    -- the supervised lifecycle, without staging real audio or
    -- depending on hardware. The actual audible behavior of
    -- the supervised path is gated on the operator running the
    -- demo manually per the slice-2 runbook.

  , testCase "selectLiveReloadRoute StoppedAudioOnly dispatches through the supervised lifecycle"
      $ selectLiveReloadRoute StoppedAudioOnly @?= LiveReloadSupervised

  , testCase "selectLiveReloadRoute RequirePreserving stays on the direct path"
      $ selectLiveReloadRoute RequirePreserving @?= LiveReloadDirect

  , testCase "selectLiveReloadRoute TryPreservingThenStoppedAudio stays on the direct path"
      $ selectLiveReloadRoute TryPreservingThenStoppedAudio @?= LiveReloadDirect
  ]

-- | Carried-issue stand-in: a payload whose textual content includes
-- both banned substrings, so the assertion is unambiguous.
leakProbe :: String
leakProbe = "PAYLOAD_TemplateGraph_RuntimeNode"

-- | Substrings that would indicate the renderer dumped the issue
-- value's 'show' into its output (the F-1 regression shape).
bannedSubstrings :: [String]
bannedSubstrings = ["TemplateGraph", "RuntimeNode"]

assertNoLeak :: String -> Assertion
assertNoLeak rendered =
  mapM_
    (\banned ->
       assertBool
         ("rendered output leaked " <> show banned <> ": " <> rendered)
         (not (banned `isInfixOf` rendered)))
    bannedSubstrings

assertShortLine :: Int -> String -> Assertion
assertShortLine cap line =
  assertBool
    ("rendered line is longer than " <> show cap
       <> " chars (was " <> show (length line) <> "): " <> line)
    (length line <= cap)

-- | Every 'HostPreservingReloadIssue' constructor as a payload-taking
-- function. Two-argument constructors get the same probe twice; this
-- is a coverage table, not a semantic fixture.
allHpariConstructors :: [String -> HostPreservingReloadIssue String]
allHpariConstructors =
  [ HpariPlanRejected
  , HpariQuiesceRejected
  , \x -> HpariQuiesceRejectedResumeFailed x x
  , HpariDrainRejected
  , \x -> HpariDrainRejectedResumeFailed x x
  , HpariDrainFailedTerminal
  , HpariReloadRejected
  , \x -> HpariReloadRejectedResumeFailed x x
  , HpariReloadFailedTerminal
  , HpariIngressRestartFailed
  ]

-- | Every 'HostStoppedAudioReloadIssue' constructor as a payload-
-- taking function.
allHsariConstructors :: [String -> HostStoppedAudioReloadIssue String]
allHsariConstructors =
  [ HsariPlanRejected
  , HsariQuiesceRejected
  , \x -> HsariQuiesceRejectedResumeFailed x x
  , HsariDrainRejected
  , \x -> HsariDrainRejectedResumeFailed x x
  , HsariDrainFailedTerminal
  , HsariStopOldAudioFailed
  , HsariReloadRejectedOldOwnerRestarted
  , \x -> HsariReloadRejectedOldOwnerRestartFailed x x
  , \x -> HsariReloadRejectedOldOwnerResumeFailed x x
  , HsariReloadFailedNoOwner
  , HsariAudioRestartFailed
  , HsariListenerRestartFailed
  ]
