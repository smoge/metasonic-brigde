{-# LANGUAGE LambdaCase #-}

-- | Phase 7.B: kind capability table tests.
--
-- Pins the invariants of the per-kind 'kindCapabilities' table:
-- every kind has at least one row, no kind claims both stateless
-- and stateful op rows, 'CapLatencyBearing' agrees with
-- 'kindLatency', 'CapSinkTerminal' agrees with the sink-kind set,
-- and 'CapResourceAccess' agrees with 'inferEff' on a
-- representative 'UGen' for each kind.
--
-- The cohort-private 'representativeUGen' helper builds one UGen
-- per 'NodeKind' for the effect cross-check and stays in this
-- module.
module MetaSonic.Spec.Feature.Capability
  ( capabilityTableTests
  ) where

import qualified Data.Set                  as S
import           Control.Monad             (forM_)
import           Data.Maybe                (isJust)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Source
import           MetaSonic.Types

------------------------------------------------------------
-- §7.B: Per-kind fusion capability table
------------------------------------------------------------

capabilityTableTests :: TestTree
capabilityTableTests =
  testGroup "Phase 7.B: kind capability table"
  [ testCase "every NodeKind has a non-empty capability row" $
      forM_ allKinds $ \k ->
        assertBool
          (show k <> " has empty kindCapabilities")
          (not (null (kindCapabilities k)))

  , testCase "no kind claims both CapStatelessOp and CapStatefulOp" $
      forM_ allKinds $ \k -> do
        let caps = S.fromList (kindCapabilities k)
        assertBool
          (show k <> " claims both stateless and stateful: "
             <> show (kindCapabilities k))
          (not (S.member CapStatelessOp caps
                && S.member CapStatefulOp caps))

  , testCase "CapLatencyBearing iff kindLatency returns Just" $
      forM_ allKinds $ \k -> do
        let bearing = CapLatencyBearing `elem` kindCapabilities k
            hasLat  = isJust (kindLatency k)
        assertEqual
          (show k <> ": CapLatencyBearing vs kindLatency mismatch")
          hasLat bearing

  , testCase "CapSinkTerminal iff k is KOut or KBusOut" $
      forM_ allKinds $ \k -> do
        let sink     = CapSinkTerminal `elem` kindCapabilities k
            isSink   = k == KOut || k == KBusOut
        assertEqual
          (show k <> ": CapSinkTerminal vs sink-kind mismatch")
          isSink sink

  , testCase "CapResourceAccess agrees with inferEff on a representative UGen" $
      forM_ allKinds $ \k -> do
        let hasAccess  = CapResourceAccess `elem` kindCapabilities k
            effs       = inferEff (representativeUGen k)
            hasNonPure = any (/= Pure) effs
        assertEqual
          (show k <> ": CapResourceAccess vs inferEff disagreement; "
             <> "representative effs=" <> show effs)
          hasNonPure hasAccess
  ]
  where
    allKinds = [minBound..maxBound] :: [NodeKind]

-- | One representative 'UGen' per 'NodeKind' for capability/effect
-- cross-checks. Connection slots use 'Param 0' (no graph dependencies
-- needed for 'inferEff'); buffer-typed kinds reference 'Buffer 0';
-- 'KStaticPlugin' uses 'identityPlugin'.
representativeUGen :: NodeKind -> UGen
representativeUGen = \case
  KSinOsc         -> SinOsc (Param 0) (Param 0)
  KSawOsc         -> SawOsc (Param 0) (Param 0)
  KPulseOsc       -> PulseOsc (Param 0) (Param 0) (Param 0)
  KTriOsc         -> TriOsc (Param 0) (Param 0)
  KNoiseGen       -> NoiseGen
  KLPF            -> LPF (Param 0) (Param 0) (Param 0)
  KHPF            -> HPF (Param 0) (Param 0) (Param 0)
  KBPF            -> BPF (Param 0) (Param 0) (Param 0)
  KNotch          -> Notch (Param 0) (Param 0) (Param 0)
  KEnv            -> Env (Param 0) (Param 0) (Param 0) (Param 0) (Param 0)
  KDelay          -> Delay 1.0 (Param 0) (Param 0)
  KSmooth         -> Smooth 1.0 (Param 0)
  KGain           -> Gain (Param 0) (Param 0)
  KAdd            -> Add (Param 0) (Param 0)
  KOut            -> Out 0 (Param 0)
  KBusOut         -> BusOut 0 (Param 0)
  KBusIn          -> BusIn 0
  KBusInDelayed   -> BusInDelayed 0
  KPlayBufMono    -> PlayBufMono (Buffer 0) (Param 0) (Param 0) (Param 0)
  KRecordBufMono  -> RecordBufMono (Buffer 0) (Param 0) (Param 0)
  KSpectralFreeze -> SpectralFreeze (Param 0) (Param 0)
  KStaticPlugin   -> StaticPlugin identityPlugin (Param 0) (Param 0)
  KSpectralLpf    -> SpectralLpf (Param 0) (Param 0)
