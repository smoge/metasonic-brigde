-- | Phase 8d-a: offline swap-artifact baseline harness.
--
-- This is intentionally narrower than an audio-capture path. It
-- reuses the same offline-driver contract as @--swap-bench@: publish
-- a prepared swap, drive one 'rt_graph_process' block to install it,
-- then read the rendered bus through 'rt_graph_read_bus'. The
-- comparison is block-aligned: an old-world continuation render is
-- compared against the post-install block from the swapped render.
module MetaSonic.Spec.Session.SwapArtifact
  ( sessionSwapArtifactTests
  ) where

import           Control.Monad                    (replicateM_)
import           Foreign.C.Types                  (CFloat (..))
import           Foreign.Marshal.Alloc            (allocaBytes)
import           Foreign.Marshal.Array            (peekArray)
import           Foreign.Ptr                      (Ptr, castPtr)
import           Foreign.Storable                 (sizeOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.Demos              (dronePreserveSmoothCutoffBright,
                                                   dronePreserveSmoothCutoffDark)
import           MetaSonic.Bridge.FFI             (RTGraph,
                                                   collectRetiredSwapStats,
                                                   c_rt_graph_process,
                                                   c_rt_graph_read_bus,
                                                   hotSwapTemplateGraph,
                                                   loadTemplateGraph,
                                                   readSwapGeneration,
                                                   smsStateCopyCount,
                                                   withRTGraph)
import           MetaSonic.Bridge.Templates       (TemplateGraph)
import           MetaSonic.Spec.SessionShared     (compileTemplateGraphOrFail,
                                                   totalTemplateNodes)


kArtifactFrames :: Int
kArtifactFrames = 256

kWarmupBlocks :: Int
-- Enough offline blocks for the old-world smoother to approach its
-- steady-state target before the swap boundary. If this number needs
-- tuning, inspect the measured signal first rather than hiding a
-- failed smoothing contract with looser thresholds.
kWarmupBlocks = 16

kSmallPeakBound :: Float
-- Phase 8d-b bounded-artifact bounds. See
-- notes/2026-05-22-d-ksmooth-preserving-state-copy-design.md (and
-- 8d-a's design note for the baseline framing). With KSmooth's IIR
-- state copied across the swap, the post-install block matches the
-- never-swapped reference render bit-for-bit on this fixture: the
-- first 8d-b run observed peak delta = 0 and RMS delta = 0. The
-- pinned bounds carry a small stability margin above zero so
-- platform-float variance doesn't flake the test on otherwise-clean
-- runs. If a future run drifts above the bound, inspect the copy
-- path first; do not relax the bound before checking whether the
-- smoother's migration semantics changed.
kSmallPeakBound = 1.0e-5

kSmallRmsBound :: Float
kSmallRmsBound = 1.0e-6

kRunawayPeakBound :: Float
kRunawayPeakBound = 1.0

kRunawayRmsBound :: Float
kRunawayRmsBound = 0.5


data ArtifactMetrics = ArtifactMetrics
  { amPeakDelta :: !Float
  , amRmsDelta  :: !Float
  } deriving (Eq, Show)


sessionSwapArtifactTests :: TestTree
sessionSwapArtifactTests =
  testGroup "Phase 8d-b: KSmooth swap artifact bounded"
  [ testCase "KSmooth preserving swap post-install artifact stays within state-copy bound" $ do
      oldGraph <- compileTemplateGraphOrFail
        [("drone", dronePreserveSmoothCutoffDark)]
      newGraph <- compileTemplateGraphOrFail
        [("drone", dronePreserveSmoothCutoffBright)]

      (oldPre, oldPost) <- renderOldContinuation oldGraph newGraph
      (swappedPre, swappedPost, stateCopies) <- renderSwappedPost oldGraph newGraph

      assertNearZero
        "pre-swap render drifted before publish"
        (artifactMetrics swappedPre oldPre)

      -- The copied-state count is the current fixture invariant:
      -- KSawOsc carrier + KLPF + KSmooth. After 8d-b, KSmooth
      -- migrates its IIR state copy-safely (per
      -- node_kind_supports_state_migration in rt_graph.cpp), so it
      -- contributes one state copy alongside the carrier and the
      -- filter.
      stateCopies @?= 3

      let metrics = artifactMetrics swappedPost oldPost
          msg = "metrics=" <> show metrics
      assertBool ("peak artifact exceeded small bound, " <> msg)
        (amPeakDelta metrics <= kSmallPeakBound)
      assertBool ("RMS artifact exceeded small bound, " <> msg)
        (amRmsDelta metrics <= kSmallRmsBound)
      assertBool ("peak gap runaway, " <> msg)
        (amPeakDelta metrics <= kRunawayPeakBound)
      assertBool ("RMS gap runaway, " <> msg)
        (amRmsDelta metrics <= kRunawayRmsBound)
  ]


renderOldContinuation :: TemplateGraph -> TemplateGraph -> IO ([Float], [Float])
renderOldContinuation oldGraph newGraph =
  withArtifactGraph oldGraph newGraph $ \rt -> do
    loadTemplateGraph rt oldGraph
    warmup rt
    pre <- renderBlock rt
    post <- renderBlock rt
    pure (pre, post)


renderSwappedPost :: TemplateGraph -> TemplateGraph -> IO ([Float], [Float], Int)
renderSwappedPost oldGraph newGraph =
  withArtifactGraph oldGraph newGraph $ \rt -> do
    loadTemplateGraph rt oldGraph
    warmup rt
    pre <- renderBlock rt

    before <- readSwapGeneration rt
    published <- hotSwapTemplateGraph
      rt
      (artifactCapacity oldGraph newGraph)
      kArtifactFrames
      newGraph
    published @?= True

    post <- renderBlock rt
    afterGen <- readSwapGeneration rt
    assertBool "expected swap generation to advance after install"
      (afterGen > before)

    stats <- collectRetiredSwapStats rt
    stateCopies <- case stats of
      Just s  -> pure (smsStateCopyCount s)
      Nothing -> assertFailure "expected retired swap stats after install"
                 >> error "unreachable"
    pure (pre, post, stateCopies)


withArtifactGraph
  :: TemplateGraph
  -> TemplateGraph
  -> (PtrRTGraph -> IO a)
  -> IO a
withArtifactGraph oldGraph newGraph =
  withRTGraph (artifactCapacity oldGraph newGraph) kArtifactFrames


type PtrRTGraph = Ptr RTGraph


artifactCapacity :: TemplateGraph -> TemplateGraph -> Int
artifactCapacity oldGraph newGraph =
  max (totalTemplateNodes oldGraph) (totalTemplateNodes newGraph) + 16


warmup :: PtrRTGraph -> IO ()
warmup rt =
  replicateM_ kWarmupBlocks $
    c_rt_graph_process rt (fromIntegral kArtifactFrames)


renderBlock :: PtrRTGraph -> IO [Float]
renderBlock rt = do
  c_rt_graph_process rt (fromIntegral kArtifactFrames)
  allocaBytes (kArtifactFrames * sizeOf (undefined :: CFloat)) $ \buf -> do
    wrote <- c_rt_graph_read_bus rt 0 (fromIntegral kArtifactFrames) (castPtr buf)
    fromIntegral wrote @?= kArtifactFrames
    samples <- peekArray kArtifactFrames buf
    pure [x | CFloat x <- samples]


artifactMetrics :: [Float] -> [Float] -> ArtifactMetrics
artifactMetrics xs ys =
  let diffs = zipWith (-) xs ys
      sq x = x * x
      peak = maximum (0.0 : map abs diffs)
      rms =
        case diffs of
          [] -> 0.0
          _  -> sqrt (sum (map sq diffs) / fromIntegral (length diffs))
  in ArtifactMetrics
       { amPeakDelta = peak
       , amRmsDelta  = rms
       }


assertNearZero :: String -> ArtifactMetrics -> Assertion
assertNearZero label metrics = do
  let msg = label <> ": metrics=" <> show metrics
  assertBool msg (amPeakDelta metrics <= 0.000001)
  assertBool msg (amRmsDelta metrics <= 0.000001)
