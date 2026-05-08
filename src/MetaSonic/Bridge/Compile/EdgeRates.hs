{-# LANGUAGE BangPatterns #-}

{- |
Module      : MetaSonic.Bridge.Compile.EdgeRates
Copyright   : (c) 2026 Bernardo Barros
License     : BSD-3-Clause

Phase 4.D.2 descriptive edge-rate survey. Reads each runtime audio
input edge ('RFrom') against the source's propagated 'rnRate' and
the destination port's 'PortConsumptionRate', then buckets the
result by @(sourceRate, destPolicy)@.

This module is read-only metadata. The C++ runtime does not consume
its output; it exists so '--fusion-survey' can ask "how many
sample-rate producers are wired into block-latched or init-only
ports" before any block-rate execution path is implemented.

The survey operates on /unfused/ 'RuntimeGraph' values (output of
'compileRuntimeGraph', not 'compileRuntimeGraphFused'). On a fused
graph, single-input rewrites replace 'RFrom' edges with 'RFused'
descriptors, which would silently shrink the edge population the
survey is meant to measure.

See Note [Per-input-port consumption policy] in "MetaSonic.Types"
for the producer-rate vs destination-policy distinction the
buckets join on.
-}

module MetaSonic.Bridge.Compile.EdgeRates
  ( EdgeRateBucket (..)
  , EdgeRateKey
  , edgeRateBuckets
  , addEdgeRateBuckets
  ) where

import           Data.List              (foldl', nub)
import qualified Data.Map.Strict        as M
import           MetaSonic.Bridge.Compile.Types
                                        ( RuntimeGraph (..)
                                        , RuntimeInput (..)
                                        , RuntimeNode (..)
                                        )
import           MetaSonic.Types        ( NodeKind
                                        , PortConsumptionRate
                                        , PortIndex (..)
                                        , PortInfo (..)
                                        , Rate
                                        , portInfo
                                        )

-- | The (source-rate, destination-port-policy) pair an edge falls
-- into. Used as the 'M.Map' key for both per-graph and aggregated
-- bucket views.
type EdgeRateKey = (Rate, PortConsumptionRate)

-- | One bucket of the edge-rate distribution: an edge count, the
-- distinct source 'NodeKind's that feed it, and a representative
-- "sourceKind → destKind.portName" example.
--
-- Producer kinds are stored as a small list rather than a 'Set'
-- because 'NodeKind' has no 'Ord' instance and the cardinality is
-- bounded by the number of declared kinds (~17). The example
-- string is the first edge encountered in source order so survey
-- output is deterministic.
data EdgeRateBucket = EdgeRateBucket
  { erbEdgeCount     :: !Int
    -- ^ Number of 'RFrom' edges in this bucket.
  , erbProducerKinds :: ![NodeKind]
    -- ^ Distinct source kinds. Aggregation 'nub's unions to keep
    -- this list deduplicated.
  , erbExample       :: !(Maybe String)
    -- ^ @"sourceKind → destKind.portName"@ for the first edge in
    -- the bucket, or 'Nothing' if the bucket is empty.
  } deriving (Eq, Show)

-- | Walk a 'RuntimeGraph''s 'RFrom' edges and bucket them by
-- @(sourceRate, destPolicy)@. Constants ('RConst') and elided
-- 'RFused' inputs are skipped: only producer-side edges with a
-- real source node contribute, since those are the ones the
-- "block-rate region" question is actually about.
--
-- The result key set may be sparse — only @(rate, policy)@ pairs
-- that actually occurred contribute a bucket.
edgeRateBuckets :: RuntimeGraph -> M.Map EdgeRateKey EdgeRateBucket
edgeRateBuckets rg =
  foldl' addEdge M.empty edges
  where
    nodeMap = M.fromList [(rnIndex n, n) | n <- rgNodes rg]

    -- Per-edge key + per-edge bucket-of-one. Yielding one bucket
    -- per edge keeps 'addEdge' a simple 'M.unionWith' call into
    -- the running map.
    edges =
      [ (key, bucketFromEdge srcKind destKind portName)
      | dst <- rgNodes rg
      , (port, RFrom srcIx _) <- zip (map PortIndex [0 ..]) (rnInputs dst)
      , Just src       <- [M.lookup srcIx nodeMap]
      , Just (PortInfo policy pname) <-
          [portInfo (rnKind dst) port]
      , let key       = (rnRate src, policy)
            srcKind   = rnKind src
            destKind  = rnKind dst
            portName  = pname
      ]

    bucketFromEdge srcKind destKind pname = EdgeRateBucket
      { erbEdgeCount     = 1
      , erbProducerKinds = [srcKind]
      , erbExample       =
          Just (show srcKind <> " → " <> show destKind <> "." <> pname)
      }

    addEdge !m (k, b) = M.insertWith mergeBucket k b m

-- | Aggregate two bucket maps with per-key merging. Producer-kind
-- lists union (via 'nub') so the result counts each kind once
-- across the merged inputs; the example prefers the left-hand
-- value so deterministic source-order survey input gives
-- deterministic survey output.
addEdgeRateBuckets
  :: M.Map EdgeRateKey EdgeRateBucket
  -> M.Map EdgeRateKey EdgeRateBucket
  -> M.Map EdgeRateKey EdgeRateBucket
addEdgeRateBuckets = M.unionWith mergeBucket

mergeBucket :: EdgeRateBucket -> EdgeRateBucket -> EdgeRateBucket
mergeBucket a b = EdgeRateBucket
  { erbEdgeCount     = erbEdgeCount a + erbEdgeCount b
  , erbProducerKinds =
      nub (erbProducerKinds a ++ erbProducerKinds b)
  , erbExample       =
      case erbExample a of
        Just _  -> erbExample a
        Nothing -> erbExample b
  }
