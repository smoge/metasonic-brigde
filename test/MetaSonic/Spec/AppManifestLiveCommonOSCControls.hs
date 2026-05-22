-- | Deterministic coverage for the pattern-level OSC control-surface
-- line renderer in "MetaSonic.App.ManifestLiveCommon".
--
-- The demo preamble's @initial OSC surface@ and @target OSC surface@
-- tables, plus the live session's startup print, route through
-- 'renderOSCControls' which now dispatches each binding through the
-- pure helper 'renderOSCControlsLine'. The line shape matches the
-- concrete addressable-surface line ('renderAddressableOSCLine') with
-- only the voice segment differing — the pattern surface uses the
-- literal @\<voice\>@ placeholder, while the addressable surface
-- resolves it to a live 'VoiceKey'. Both surfaces share the
-- @(name=..., default=..., range=[..., ...], cc=...)@ metadata tail
-- so an operator scanning either reads the same units and ranges.
--
-- The four rows below pin:
--
--   * normal range with a CC binding;
--   * normal range without a CC binding (the @, cc=...@ field is
--     omitted, not rendered as @cc=null@);
--   * zero-width range (rangeMin == rangeMax) — degenerate but legal;
--   * fractional default and bounds.
module MetaSonic.Spec.AppManifestLiveCommonOSCControls
  ( appManifestLiveCommonOSCControlsTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveCommon       (renderOSCControlsLine)
import           MetaSonic.App.ManifestReloadOSCBinding (ManifestOSCControlBinding (..))
import           MetaSonic.Bridge.Source                (MigrationKey (..))
import           MetaSonic.Pattern                      (ControlTag (..))


appManifestLiveCommonOSCControlsTests :: TestTree
appManifestLiveCommonOSCControlsTests =
  testGroup "App manifest live common: pattern-level OSC control-surface renderer"
  [ testCase "normal range with CC renders default, range, and cc= suffix" $
      renderOSCControlsLine
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "lpf") 0
          , mocbDisplayName = "cutoff"
          , mocbDefault     = 600.0
          , mocbRangeMin    = 200.0
          , mocbRangeMax    = 6000.0
          , mocbCC          = Just 74
          }
        @?= "/<voice>/lpf/0  (name=\"cutoff\", default=600.0, range=[200.0, 6000.0], cc=74)"

  , testCase "normal range without CC omits the cc= suffix entirely" $
      renderOSCControlsLine
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "cutoff") 1
          , mocbDisplayName = "cutoff"
          , mocbDefault     = 1200.0
          , mocbRangeMin    = 200.0
          , mocbRangeMax    = 8000.0
          , mocbCC          = Nothing
          }
        @?= "/<voice>/cutoff/1  (name=\"cutoff\", default=1200.0, range=[200.0, 8000.0])"

  , testCase "zero-width range renders without special-casing" $
      -- Degenerate-but-legal: rangeMin == rangeMax. The renderer is
      -- format-only; accept-predicate semantics for the single-valued
      -- control live at the ingress (commit f0b5912 / b22d1a9).
      renderOSCControlsLine
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "bias") 0
          , mocbDisplayName = "bias"
          , mocbDefault     = 0.0
          , mocbRangeMin    = 0.0
          , mocbRangeMax    = 0.0
          , mocbCC          = Nothing
          }
        @?= "/<voice>/bias/0  (name=\"bias\", default=0.0, range=[0.0, 0.0])"

  , testCase "fractional default and bounds render exactly as Double show produces" $
      -- Same 'show :: Double -> String' format the addressable
      -- surface and the (out-of-range) rejection line use, so values
      -- can be copied between operator-facing diagnostics without
      -- unit drift.
      renderOSCControlsLine
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "vol") 0
          , mocbDisplayName = "vol"
          , mocbDefault     = 0.3
          , mocbRangeMin    = 0.0
          , mocbRangeMax    = 1.0
          , mocbCC          = Just 10
          }
        @?= "/<voice>/vol/0  (name=\"vol\", default=0.3, range=[0.0, 1.0], cc=10)"
  ]
