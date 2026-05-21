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
import qualified Data.Text                              as T
import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveReloadDemo   (LiveReloadRoute (..),
                                                         SupervisedFactoryFlavor (..),
                                                         renderLiveReloadRoute,
                                                         selectLiveReloadRoute)
import           MetaSonic.App.ManifestOSCIngressOps    (ManifestOSCIngressOpsIssue)
import           MetaSonic.App.ManifestReloadCli        (renderHostPreservingIssueTag,
                                                         renderHostStoppedAudioIssueTag,
                                                         renderPreservingHostStackIssueTag,
                                                         renderReloadHostStackOpenIssueTag,
                                                         renderSmokeReloadEvent,
                                                         renderStoppedAudioHostStackIssueTag,
                                                         renderStrategyRan,
                                                         renderTryPreservingHostStackIssueTag,
                                                         renderTryPreservingInWindowIssueTag)
import           MetaSonic.App.ManifestReloadEvent      (ManifestReloadEvent (..))
import           MetaSonic.App.ManifestReloadHost       (ManifestReloadHostIssue (..),
                                                         ManifestReloadHostStrategy (..),
                                                         ManifestReloadHostStrategyRan (..))
import           MetaSonic.App.ManifestReloadHostStack  (ReloadHostStackOpenIssue (..),
                                                         StoppedAudioHostStackIssue (..))
import           MetaSonic.App.ManifestReloadOrchestration
                                                        (HostPreservingReloadIssue (..),
                                                         HostStoppedAudioReloadIssue (..))
import           MetaSonic.App.ManifestReloadPreservingHostStack
                                                        (PreservingHostStackIssue (..))
import           MetaSonic.App.ManifestReloadTryPreservingHostStack
                                                        (TryPreservingHostStackIssue (..),
                                                         TryPreservingInWindowIssue (..))
import qualified MetaSonic.Session.ManifestReload      as MR


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

    -- §219 routing: the audible @--manifest-live-reload-demo@
    -- now dispatches all three strategies through the supervised
    -- lifecycle — StoppedAudioOnly through
    -- 'realStoppedAudioHostStackOps', TryPreservingThenStoppedAudio
    -- through 'realTryPreservingHostStackOps' (composed
    -- preserving + stopped-audio fallback), and RequirePreserving
    -- through 'realPreservingHostStackOps' (preserving-only).
    --
    -- 'selectLiveReloadRoute' is a pure selector. Pinning each
    -- strategy's route here catches a class of regressions
    -- where a refactor silently changes which strategies use
    -- the supervised lifecycle, without staging real audio or
    -- depending on hardware. The actual audible behavior of the
    -- supervised paths is gated on the operator running the
    -- demo manually per the slice-2 runbook.

  , testCase "selectLiveReloadRoute StoppedAudioOnly -> supervised stopped-audio"
      $ selectLiveReloadRoute StoppedAudioOnly
          @?= LiveReloadSupervised SfStoppedAudio

  , testCase "selectLiveReloadRoute TryPreservingThenStoppedAudio -> supervised try-preserving"
      $ selectLiveReloadRoute TryPreservingThenStoppedAudio
          @?= LiveReloadSupervised SfTryPreserving

  , testCase "selectLiveReloadRoute RequirePreserving -> supervised require-preserving"
      $ selectLiveReloadRoute RequirePreserving
          @?= LiveReloadSupervised SfRequirePreserving

    -- The tier-2 smoke wrappers (tools/manifest_supervised_*_live_smoke.sh)
    -- grep on the exact 'route:' string in the demo preamble.
    -- These tests pin those strings so a refactor of
    -- 'renderLiveReloadRoute' breaks here loudly instead of
    -- silently breaking the wrapper marker check.

  , testCase "renderLiveReloadRoute LiveReloadDirect"
      $ renderLiveReloadRoute LiveReloadDirect
          @?= "direct (reloadManifestHostWithStrategy)"

  , testCase "renderLiveReloadRoute LiveReloadSupervised SfStoppedAudio"
      $ renderLiveReloadRoute (LiveReloadSupervised SfStoppedAudio)
          @?= "supervised (stopped-audio; reloadSupervised + HostStackFactory)"

  , testCase "renderLiveReloadRoute LiveReloadSupervised SfTryPreserving"
      $ renderLiveReloadRoute (LiveReloadSupervised SfTryPreserving)
          @?= "supervised (try-preserving; reloadSupervised + HostStackFactory)"

  , testCase "renderLiveReloadRoute LiveReloadSupervised SfRequirePreserving"
      $ renderLiveReloadRoute (LiveReloadSupervised SfRequirePreserving)
          @?= "supervised (require-preserving; reloadSupervised + HostStackFactory)"

    -- The new 'MrePreservingReloadEnqueueRejected' constructor must
    -- be reachable through 'renderSmokeReloadEvent' (and therefore
    -- 'renderLiveReloadEvents'), or its appearance in the timeline
    -- would silently fall back to the @Show@-derived default. The
    -- assertion pins the exact operator line for an inner
    -- 'MrhiPlanning' issue ("planning" tag); production wraps the
    -- issue in 'MrhiPreservingReloadRejected' through
    -- 'mapPreservingReloadReport' so the realistic tag will be
    -- "preserving-reload-rejected", but the inner choice does not
    -- change the wiring this test pins.

  , testCase "renderSmokeReloadEvent wires up MrePreservingReloadEnqueueRejected" $ do
      let issue :: ManifestReloadHostIssue ManifestOSCIngressOpsIssue
          issue = MrhiPlanning (MR.MriUnknownManifestDemo "probe-demo")
          event = MrePreservingReloadEnqueueRejected issue
      renderSmokeReloadEvent event
        @?= "    - preserving reload enqueue rejected: planning"

    -- F-1 leak guards for the live-session supervised-cause
    -- renderers. The 2026-05-21-a reject-path operator pass found
    -- 'runReloadWith' was printing 'show cause' on a host-stack
    -- issue value that recursively unrolled a full
    -- 'ManifestPreservingHotSwapReport' (~13 KB / single line, two
    -- complete 'TemplateGraph' records). These tests pin the
    -- structural shape of each route's renderer and assert the
    -- carried payload cannot leak through any branch of the four
    -- wrappers ('renderReloadHostStackOpenIssueTag',
    -- 'renderPreservingHostStackIssueTag',
    -- 'renderStoppedAudioHostStackIssueTag',
    -- 'renderTryPreservingInWindowIssueTag', and
    -- 'renderTryPreservingHostStackIssueTag').

  , testCase "renderReloadHostStackOpenIssueTag pins the polymorphic IngressOpen branch" $ do
      let rendered = renderReloadHostStackOpenIssueTag
                       (RhsoiIngressOpenFailed leakProbe)
      rendered @?= "ingress-open-failed"
      assertNoLeak rendered

  , testCase "renderReloadHostStackOpenIssueTag drops the diagnostic Text on PartialCleanupFailed" $ do
      -- Both halves carry payload: the primary issue carries the
      -- polymorphic leakProbe, the diagnostic Text carries a fake
      -- banned-substring fragment. Neither must reach the rendered
      -- line; only the kebab tags do.
      let primary = RhsoiIngressOpenFailed leakProbe
          rendered = renderReloadHostStackOpenIssueTag
                       (RhsoiPartialCleanupFailed
                         primary
                         (T.pack "TemplateGraph diagnostic"))
      rendered @?= "partial-cleanup-failed (ingress-open-failed)"
      assertNoLeak rendered

  , testCase "renderPreservingHostStackIssueTag never leaks across every HostPreservingReloadIssue constructor (PahsiInWindow)" $
      mapM_
        (\mkIssue ->
           let rendered = renderPreservingHostStackIssueTag
                            (PahsiInWindow (mkIssue leakProbeHostIssue))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        allHpariOnHostIssue

  , testCase "renderPreservingHostStackIssueTag pins the PahsiOpen branch" $ do
      let rendered = renderPreservingHostStackIssueTag
                       (PahsiOpen (RhsoiIngressOpenFailed leakProbe))
      rendered @?= "open: ingress-open-failed"
      assertNoLeak rendered

  , testCase "renderStoppedAudioHostStackIssueTag never leaks across every HostStoppedAudioReloadIssue constructor (SahsiInWindow)" $
      mapM_
        (\mkIssue ->
           let rendered = renderStoppedAudioHostStackIssueTag
                            (SahsiInWindow (mkIssue leakProbeHostIssue))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        allHsariOnHostIssue

  , testCase "renderStoppedAudioHostStackIssueTag pins the SahsiOpen branch" $ do
      let rendered = renderStoppedAudioHostStackIssueTag
                       (SahsiOpen (RhsoiIngressOpenFailed leakProbe))
      rendered @?= "open: ingress-open-failed"
      assertNoLeak rendered

  , testCase "renderTryPreservingInWindowIssueTag never leaks (PreservingFallbackDeclined)" $
      mapM_
        (\mkIssue ->
           let rendered = renderTryPreservingInWindowIssueTag
                            (TpiwiPreservingFallbackDeclined
                              (mkIssue leakProbeHostIssue))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        allHpariOnHostIssue

  , testCase "renderTryPreservingInWindowIssueTag never leaks (PreservingTerminal)" $
      mapM_
        (\mkIssue ->
           let rendered = renderTryPreservingInWindowIssueTag
                            (TpiwiPreservingTerminal
                              (mkIssue leakProbeHostIssue))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        allHpariOnHostIssue

  , testCase "renderTryPreservingInWindowIssueTag never leaks (FallbackStoppedAudioFailed, both halves)" $
      mapM_
        (\(mkPrev, mkCurr) ->
           let rendered = renderTryPreservingInWindowIssueTag
                            (TpiwiFallbackStoppedAudioFailed
                              (mkPrev leakProbeHostIssue)
                              (mkCurr leakProbeHostIssue))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        [ (prev, curr)
        | prev <- allHpariOnHostIssue
        , curr <- allHsariOnHostIssue
        ]

  , testCase "renderTryPreservingHostStackIssueTag pins the TpahsiOpen branch" $ do
      let rendered = renderTryPreservingHostStackIssueTag
                       (TpahsiOpen (RhsoiIngressOpenFailed leakProbe))
      rendered @?= "open: ingress-open-failed"
      assertNoLeak rendered

  , testCase "renderTryPreservingHostStackIssueTag never leaks (TpahsiInWindow with PreservingFallbackDeclined)" $
      mapM_
        (\mkIssue ->
           let rendered = renderTryPreservingHostStackIssueTag
                            (TpahsiInWindow
                              (TpiwiPreservingFallbackDeclined
                                (mkIssue leakProbeHostIssue)))
           in do
             assertNoLeak rendered
             assertShortLine 300 rendered)
        allHpariOnHostIssue
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

-- | Probe-laden 'ManifestReloadHostIssue' value at type
-- 'ManifestReloadHostIssue String'. Used by the supervised-cause
-- wrapper tests below: the in-window arms of those wrappers carry
-- @HostPreservingReloadIssue (ManifestReloadHostIssue ingressIssue)@
-- / @HostStoppedAudioReloadIssue ...@, so the inner payload type
-- must be 'ManifestReloadHostIssue', not a raw 'String'. Wrapping
-- 'leakProbe' through 'MrhiIngress' threads the banned-substring
-- payload one level deeper so any leak through the wrapper's
-- recursive 'show' or accidental payload embedding would surface.
leakProbeHostIssue :: ManifestReloadHostIssue String
leakProbeHostIssue = MrhiIngress leakProbe

-- | 'allHpariConstructors' lifted to operate at the host-issue
-- type. Same constructors, different element type. The duplicated
-- table is intentional — kept verbatim so a future Hpari constructor
-- gets surfaced as a kindTag-style drift between the two lists.
allHpariOnHostIssue
  :: [ManifestReloadHostIssue String
      -> HostPreservingReloadIssue (ManifestReloadHostIssue String)]
allHpariOnHostIssue =
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

-- | 'allHsariConstructors' lifted to operate at the host-issue
-- type. Same constructors, different element type.
allHsariOnHostIssue
  :: [ManifestReloadHostIssue String
      -> HostStoppedAudioReloadIssue (ManifestReloadHostIssue String)]
allHsariOnHostIssue =
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
