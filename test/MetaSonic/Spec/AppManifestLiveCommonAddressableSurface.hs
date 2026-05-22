-- | Deterministic coverage for the addressable-OSC-surface line
-- renderer in "MetaSonic.App.ManifestLiveCommon".
--
-- The startup-time print at 'printAddressableSurface' routes through
-- the exported pure helper 'renderAddressableOSCLine' so the
-- per-binding rendering can be pinned as an operator-string contract
-- without staging session IO. The first operator pass surfaced a
-- units-confusion bug (writing @0.75@ to a cutoff bound in Hz with
-- declared range @[200, 6000]@) that the previous render —
-- @\/v0\/lpf\/0  (name="cutoff")@ — could not have preempted because
-- it carried no unit / range / default information. The new
-- per-binding line surfaces @default=@, @range=[lo, hi]@, and an
-- optional @cc=@ suffix so the operator can read the unit convention
-- without consulting the manifest source.
module MetaSonic.Spec.AppManifestLiveCommonAddressableSurface
  ( appManifestLiveCommonAddressableSurfaceTests
  ) where

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestLiveCommon       (renderAddressableOSCLine)
import           MetaSonic.App.ManifestReloadOSCBinding (ManifestOSCControlBinding (..))
import           MetaSonic.Bridge.Source                (MigrationKey (..))
import           MetaSonic.Pattern                      (ControlTag (..),
                                                         VoiceKey (..))


appManifestLiveCommonAddressableSurfaceTests :: TestTree
appManifestLiveCommonAddressableSurfaceTests =
  testGroup "App manifest live common: addressable OSC surface renderer"
  [ testCase "binding with CC renders default, range, and cc= suffix" $
      renderAddressableOSCLine
        (VoiceKey "v0")
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "lpf") 0
          , mocbDisplayName = "cutoff"
          , mocbDefault     = 600.0
          , mocbRangeMin    = 200.0
          , mocbRangeMax    = 6000.0
          , mocbCC          = Just 74
          }
        @?= "/v0/lpf/0  (name=\"cutoff\", default=600.0, range=[200.0, 6000.0], cc=74)"

  , testCase "binding without CC omits the cc= suffix entirely" $
      -- The trailing ', cc=...' field is omitted (not rendered as
      -- 'cc=null' or 'cc=') when mocbCC is Nothing. The closing
      -- paren sits flush against the range bracket.
      renderAddressableOSCLine
        (VoiceKey "v0")
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "cutoff") 1
          , mocbDisplayName = "cutoff"
          , mocbDefault     = 1200.0
          , mocbRangeMin    = 200.0
          , mocbRangeMax    = 8000.0
          , mocbCC          = Nothing
          }
        @?= "/v0/cutoff/1  (name=\"cutoff\", default=1200.0, range=[200.0, 8000.0])"

  , testCase "fractional range bounds render exactly as Double show produces" $
      -- The range bounds and default come from the manifest as
      -- 'Double'; the renderer uses 'show :: Double -> String'
      -- directly so the operator surface matches what the rejection
      -- line in 'renderOSCIssueLine' produces. No clamping, no
      -- pretty-printing.
      renderAddressableOSCLine
        (VoiceKey "fx")
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "vol") 0
          , mocbDisplayName = "vol"
          , mocbDefault     = 0.3
          , mocbRangeMin    = 0.0
          , mocbRangeMax    = 1.0
          , mocbCC          = Just 10
          }
        @?= "/fx/vol/0  (name=\"vol\", default=0.3, range=[0.0, 1.0], cc=10)"

  , testCase "zero-width range renders without special-casing" $
      -- Degenerate-but-legal: rangeMin == rangeMax. The renderer is
      -- format-only, so the surface still shows the manifest's
      -- declared shape. The accept predicate side (commit f0b5912)
      -- handles the only-the-exact-midpoint semantics.
      renderAddressableOSCLine
        (VoiceKey "v0")
        ManifestOSCControlBinding
          { mocbControlTag  = ControlTag (MigrationKey "bias") 0
          , mocbDisplayName = "bias"
          , mocbDefault     = 0.0
          , mocbRangeMin    = 0.0
          , mocbRangeMax    = 0.0
          , mocbCC          = Nothing
          }
        @?= "/v0/bias/0  (name=\"bias\", default=0.0, range=[0.0, 0.0])"
  ]
