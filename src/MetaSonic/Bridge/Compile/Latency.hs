{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Bridge.Compile.Latency
-- Description : Descriptive declared-latency analysis for RuntimeGraph.
--
-- This module is deliberately read-only. It consumes
-- 'nodeDeclaredLatency', which is per-instance for 'KStaticPlugin'
-- (consulting the plugin catalog through the frozen @plugin_id@ in
-- 'rnControls') and kind-level via 'kindLatency' for every other
-- kind. It reports where inherent node latency appears. No scheduler
-- pass consumes the result in 6.D / 6.E; compensation remains a
-- later decision.

module MetaSonic.Bridge.Compile.Latency
  ( DeclaredNodeLatency (..)
  , InputLatency (..)
  , LatencySkew (..)
  , nodeDeclaredLatency
  , declaredLatencyFootprint
  , nodeOutputLatencies
  , inputLatencySkews
  ) where

import           Control.DeepSeq     (NFData)
import qualified Data.Map.Strict     as M
import           Data.Maybe          (listToMaybe, mapMaybe)
import           GHC.Generics        (Generic)

import           MetaSonic.Bridge.Compile.Types
import           MetaSonic.Bridge.Source (finitePluginId, spiLatencySamples,
                                         staticPluginInfoById)
import           MetaSonic.Types

-- | One compiled node whose kind declares inherent steady-state
-- pipeline latency.
data DeclaredNodeLatency = DeclaredNodeLatency
  { dnlNode    :: !NodeIndex
  , dnlKind    :: !NodeKind
  , dnlLatency :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The cumulative latency observed at one dynamic input of a node.
-- Constants are omitted because they do not represent an audio path.
data InputLatency = InputLatency
  { ilPort    :: !PortIndex
  , ilSource  :: !NodeIndex
  , ilLatency :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | A node that combines dynamic inputs with different cumulative
-- latency. This is a diagnostic only: the graph still compiles and
-- runs exactly as before.
data LatencySkew = LatencySkew
  { lsNode       :: !NodeIndex
  , lsKind       :: !NodeKind
  , lsInputs     :: ![InputLatency]
  , lsMinLatency :: !Int
  , lsMaxLatency :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Per-instance declared latency for a 'RuntimeNode'.
--
-- For 'KStaticPlugin', resolves the frozen @plugin_id@ from
-- @rnControls@ through the catalog: a positive @spiLatencySamples@
-- becomes 'Just', and zero stays 'Nothing'. For every other kind,
-- defers to 'kindLatency'.
--
-- The "zero latency is reported as 'Nothing', not 'Just 0'"
-- invariant matches 'kindLatency', so existing consumers can swap
-- to this accessor without re-shaping their filter logic. An
-- unresolvable plugin_id (empty controls, non-finite, out-of-range
-- value, or missing catalog row) returns 'Nothing'.
nodeDeclaredLatency :: RuntimeNode -> Maybe Int
nodeDeclaredLatency n =
  case rnKind n of
    KStaticPlugin -> do
      pidD <- listToMaybe (rnControls n)
      pid  <- finitePluginId pidD
      info <- staticPluginInfoById pid
      let lat = spiLatencySamples info
      if lat > 0 then Just lat else Nothing
    other -> kindLatency other

-- | Every node in the graph whose declared latency is positive.
--
-- Latency for 'KStaticPlugin' is per-instance (catalog row keyed
-- by the node's frozen @plugin_id@); kind-level for every other
-- kind. The trailing @lat > 0@ filter is redundant under
-- 'nodeDeclaredLatency' (which itself returns 'Nothing' for zero)
-- but stays as a belt-and-suspenders guard.
declaredLatencyFootprint :: RuntimeGraph -> [DeclaredNodeLatency]
declaredLatencyFootprint rg =
  [ DeclaredNodeLatency (rnIndex n) (rnKind n) lat
  | n <- rgNodes rg
  , Just lat <- [nodeDeclaredLatency n]
  , lat > 0
  ]

-- | Cumulative output latency per node, in samples.
--
-- The value is descriptive: for a node with multiple dynamic inputs,
-- the propagated output latency is the maximum input latency plus
-- that node's own declared latency. 'inputLatencySkews' reports the
-- lossy part of that simplification separately when inputs disagree.
nodeOutputLatencies :: RuntimeGraph -> M.Map NodeIndex Int
nodeOutputLatencies rg =
  foldl' step M.empty (rgNodes rg)
  where
    step acc n =
      let inputLats = map ilLatency (dynamicInputLatencies acc n)
          upstream  = if null inputLats then 0 else maximum inputLats
          own       = maybe 0 id (nodeDeclaredLatency n)
      in M.insert (rnIndex n) (upstream + own) acc

-- | Nodes whose dynamic inputs arrive at different cumulative
-- latencies. This is the first consumer-facing diagnostic that can
-- justify a later compensation pass.
inputLatencySkews :: RuntimeGraph -> [LatencySkew]
inputLatencySkews rg =
  let outputLats = nodeOutputLatencies rg
  in mapMaybe (skewFor outputLats) (rgNodes rg)
  where
    skewFor outputLats n =
      let inputs = dynamicInputLatencies outputLats n
          lats   = map ilLatency inputs
      in case lats of
           [] -> Nothing
           _  ->
             let lo = minimum lats
                 hi = maximum lats
             in if lo == hi
                  then Nothing
                  else Just LatencySkew
                    { lsNode       = rnIndex n
                    , lsKind       = rnKind n
                    , lsInputs     = inputs
                    , lsMinLatency = lo
                    , lsMaxLatency = hi
                    }

dynamicInputLatencies
  :: M.Map NodeIndex Int
  -> RuntimeNode
  -> [InputLatency]
dynamicInputLatencies outputLats n =
  mapMaybe inputLatency (zip [0 :: Int ..] (rnInputs n))
  where
    inputLatency (slot, RFrom src _srcPort) =
      Just InputLatency
        { ilPort    = PortIndex slot
        , ilSource  = src
        , ilLatency = M.findWithDefault 0 src outputLats
        }
    inputLatency (slot, RFused fused) =
      let src = fusedSourceNode fused
      in Just InputLatency
        { ilPort    = PortIndex slot
        , ilSource  = src
        , ilLatency = M.findWithDefault 0 src outputLats
        }
    inputLatency (_slot, RConst _) = Nothing

fusedSourceNode :: FusedInput -> NodeIndex
fusedSourceNode FScaleFrom { fiSourceNode = src } = src
fusedSourceNode FScaleChainFrom { fcSourceNode = src } = src
fusedSourceNode FAffineFrom { faSourceNode = src } = src
