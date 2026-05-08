{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : MetaSonic.Bridge.Compile
-- Description : Facade for the compile pipeline. Re-exports the
--               public surface from sibling 'Compile.*' modules
--               and provides the orchestration entry points
--               ('compileRuntimeGraph', 'compileRuntimeGraphFused')
--               that wire them together.
--
-- The implementation is split into five sibling modules:
--
--   * "MetaSonic.Bridge.Compile.Types"        — dense data shapes
--   * "MetaSonic.Bridge.Compile.Regions"      — IR-level region formation
--   * "MetaSonic.Bridge.Compile.RegionKernels"— §4.B fused-kernel selection
--   * "MetaSonic.Bridge.Compile.Dependencies" — per-region footprints,
--                                               dependency views,
--                                               §4.E.1c barrier predicate
--   * "MetaSonic.Bridge.Compile.Fusion"       — §4.C scalar affine fusion
--
-- This module re-exports their public surface so existing
-- @import MetaSonic.Bridge.Compile@ call-sites keep working
-- without churn. New code can import the sibling modules directly
-- when it only needs one layer.
module MetaSonic.Bridge.Compile
  ( -- * Runtime representation
    --
    -- From "MetaSonic.Bridge.Compile.Types".
    RuntimeInput (..)
  , FusedInput (..)
  , ScaleRef (..)
  , AffineStep (..)
  , RuntimeNode (..)
  , RuntimeRegion (..)
  , RegionKernel (..)
  , kernelTag
  , RuntimeGraph (..)
  , RegionIndex (..)
  , NodeOutputUse (..)
  , -- * Bus footprints
    --
    -- From "MetaSonic.Bridge.Compile.Types" + "MetaSonic.Bridge.Compile.Dependencies".
    -- See Note [Bus footprints, template- vs region-level] in
    -- 'MetaSonic.Bridge.Compile.Types'.
    BusFootprint (..)
  , emptyFootprint
  , runtimeNodeFootprint
  , regionFootprint
  , attachRegionFootprints
  , -- * Region dependency views
    --
    -- From "MetaSonic.Bridge.Compile.Dependencies". See
    -- Note [Region dependency contract] in that module.
    inputSourceIndex
  , fusedInputSource
  , regionBusPrecedence
  , regionStructuralPrecedence
  , regionDependencies
  , -- * Scheduler barrier predicate
    --
    -- From "MetaSonic.Bridge.Compile.Dependencies". See
    -- Note [Region barrier policy] in that module.
    isLiveBusKind
  , regionHasLiveBus
  , -- * Compilation
    compileRuntimeGraph
  , compileRuntimeGraphUnfused
  , compileRuntimeGraphFused
  , fuseRuntimeGraph
  , selectRegionKernels
  , resolveNodeIndex
  , -- * Region formation
    --
    -- From "MetaSonic.Bridge.Compile.Regions".
    RegionID (..)
  , Region (..)
  , RegionGraph (..)
  , formRegions
  ) where

import qualified Data.Map.Strict as M

import           MetaSonic.Bridge.IR
import           MetaSonic.Types

import           MetaSonic.Bridge.Compile.Types
import           MetaSonic.Bridge.Compile.Regions
import           MetaSonic.Bridge.Compile.RegionKernels
import           MetaSonic.Bridge.Compile.Dependencies
import           MetaSonic.Bridge.Compile.Fusion

-- | Look up the dense 'NodeIndex' that a given symbolic 'NodeID'
-- compiled to. Returns 'Nothing' if the 'NodeID' isn't present in
-- the graph (e.g. a stray ID from a different graph, or one that
-- was elided by a future fusion pass).
--
-- The intended use is post-compile binding: the source DSL
-- accumulates symbolic 'NodeID's; the runtime ABI takes dense
-- 'NodeIndex'es; this resolver bridges the two so MIDI/CC/observability
-- code can target a specific compiled node.
resolveNodeIndex :: RuntimeGraph -> NodeID -> Maybe NodeIndex
resolveNodeIndex rg nid =
  rnIndex <$> lookupNode (rgNodes rg)
  where
    lookupNode []                       = Nothing
    lookupNode (n:ns)
      | rnOriginalID n == nid           = Just n
      | otherwise                       = lookupNode ns

-- | Compile a 'GraphIR' into a dense 'RuntimeGraph'.
--
-- Fails if any symbolic reference cannot be resolved to a
-- dense index (which would indicate a bug in earlier passes,
-- since validation already checked referential integrity).
--
-- Pipeline (in order):
--
--   1. Build NodeID → NodeIndex map from execution order.
--   2. 'formRegions' on the IR; lower each compile-time 'Region'
--      to a dense 'RuntimeRegion' via 'compileRegion'.
--   3. Output-use classification (Step B-Light) over each node.
--   4. Lower each 'NodeIR' to a 'RuntimeNode'.
--   5. 'selectRegionKernels' (§4.B) to claim fused-kernel shapes.
--   6. 'attachRegionFootprints' to populate per-region
--      'BusFootprint' for §4.E.1+ scheduler metadata.
--
-- See Note [Dense lowering] in 'MetaSonic.Bridge.Compile.Types'.
compileRuntimeGraph :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraph ir = do
  let !irNodes = giNodes ir

      -- Build the decisive map: NodeID → NodeIndex.
      -- The index is the node's position in execution order.
      !indexMap = M.fromList
        [ (irNodeID n, NodeIndex i)
        | (i, n) <- zip [0..] irNodes
        ]

  -- Region overlay: form regions from the IR, then translate the
  -- per-region NodeID membership into the dense NodeIndex space.
  -- See Note [Runtime regions overlay] in 'Compile.Types'.
  rtRegions <- mapM (compileRegion indexMap)
                    (zip [0..] (rgRegions (formRegions irNodes)))

  -- Output-use classification (Step B-Light): for each NodeIndex, look
  -- up the region it belongs to, then check whether every consumer
  -- lives in that same region. Sinks ('KOut'/'KBusOut') skip the check
  -- entirely and land in 'NoOutput'.
  -- See Note [Output-use classification] in 'Compile.Types'.
  let !nodeRegion = M.fromList
        [ (ix, rrIndex r)
        | r <- rtRegions, ix <- rrNodes r
        ]

      -- Consumer map built from the (still-symbolic) IR inputs:
      -- for each consumer node, every 'FromNode src _' contributes a
      -- (src, consumer) edge. We translate via indexMap to NodeIndex
      -- so the keys and values live in the same dense space as
      -- 'nodeRegion'.
      !consumerMap = M.fromListWith (++)
        [ (srcIx, [consumerIx])
        | n <- irNodes
        , let consumerIx = indexMap M.! irNodeID n
        , FromNode srcID _ <- irInputs n
        , Just srcIx <- [M.lookup srcID indexMap]
        ]

      classify :: NodeIndex -> NodeKind -> NodeOutputUse
      classify _   KOut    = NoOutput
      classify _   KBusOut = NoOutput
      classify ix _        =
        let myRegion = M.lookup ix nodeRegion
            consumers = M.findWithDefault [] ix consumerMap
            allLocal  = all (\c -> M.lookup c nodeRegion == myRegion) consumers
        in if allLocal then RegionLocal else RegionEscapes

      consumerCount :: NodeIndex -> Int
      consumerCount ix = length (M.findWithDefault [] ix consumerMap)

  rtNodes <- mapM (compileNode indexMap classify consumerCount) (zip [0..] irNodes)

  -- §4.B region kernel selection runs as the last step of compile,
  -- before any §4.C-style elision pass. Tagging happens here so
  -- 'fuseRuntimeGraph' (which §4.C's 'compileRuntimeGraphFused'
  -- runs next) can skip nodes that have already been claimed by a
  -- fused region kernel — otherwise §4.C would elide a Gain that
  -- the region kernel still expects to address by control slot.
  -- See Note [Region kernel selection] in 'Compile.RegionKernels'.
  --
  -- 'attachRegionFootprints' runs /after/ kernel selection so the
  -- per-region 'BusFootprint' reflects the post-split member list
  -- — §4.E.1 metadata, no runtime behavior change.
  pure $!
    attachRegionFootprints
      (selectRegionKernels (RuntimeGraph rtNodes rtRegions))

  where
    compileNode
      :: M.Map NodeID NodeIndex
      -> (NodeIndex -> NodeKind -> NodeOutputUse)
      -> (NodeIndex -> Int)
      -> (Int, NodeIR)
      -> Either String RuntimeNode
    compileNode indexMap classify consumerCount (i, node) = do
      inputs <- mapM (compileInput indexMap) (irInputs node)
      let !ix   = NodeIndex i
          !kind = irKind node
      pure $! RuntimeNode
        { rnIndex         = ix
        , rnOriginalID    = irNodeID node
        , rnKind          = kind
        , rnInputs        = inputs
        , rnControls      = irControls node
        , rnOutputUse     = classify ix kind
        , rnConsumerCount = consumerCount ix
        , rnElided        = False
          -- compileRuntimeGraph never elides; only fuseRuntimeGraph
          -- (Step C) flips this to True for nodes absorbed by a
          -- fused consumer input. See Note [Fused inputs].
        }

    -- Rewrite a symbolic InputConn to a dense RuntimeInput.
    -- See Note [Dense lowering] in 'Compile.Types'.
    compileInput
      :: M.Map NodeID NodeIndex
      -> InputConn
      -> Either String RuntimeInput
    compileInput _ (Literal x) = Right (RConst x)
    compileInput indexMap (FromNode src port) =
      case M.lookup src indexMap of
        Nothing -> Left $ "Missing runtime index for " ++ show src
        Just ix -> Right (RFrom ix port)

    -- Translate a compile-time 'Region' into a dense 'RuntimeRegion'.
    -- The 'regNodes' field is a list of symbolic 'NodeID's; we look
    -- each up in the same NodeID → NodeIndex map used by node lowering.
    -- A miss is the same kind of internal-bug case as in 'compileInput'.
    -- See Note [Runtime regions overlay] in 'Compile.Types'.
    compileRegion
      :: M.Map NodeID NodeIndex
      -> (Int, Region)
      -> Either String RuntimeRegion
    compileRegion indexMap (i, region) = do
      members <- mapM (lookupNodeIndex indexMap) (regNodes region)
      pure $! RuntimeRegion
        { rrIndex  = RegionIndex i
        , rrRate   = regRate region
        , rrNodes  = members
        , rrKernel = RNodeLoop
          -- Default for every region produced by 'formRegions'.
          -- 'selectRegionKernels' may upgrade some regions to a
          -- fused kernel after splitting, before the final
          -- 'RuntimeGraph' is returned.
        , rrFootprint = emptyFootprint
          -- Placeholder; 'attachRegionFootprints' fills this in as
          -- the final step of 'compileRuntimeGraph' so kernel splits
          -- don't leave stale aggregations behind.
        }

    lookupNodeIndex
      :: M.Map NodeID NodeIndex
      -> NodeID
      -> Either String NodeIndex
    lookupNodeIndex indexMap nid =
      case M.lookup nid indexMap of
        Nothing -> Left $ "Missing runtime index for region member "
                       ++ show nid
        Just ix -> Right ix

-- | Alias for 'compileRuntimeGraph'. Provided so callers can opt
-- explicitly into the unfused path (today's default behavior) and
-- be paired with 'compileRuntimeGraphFused' at the call site.
compileRuntimeGraphUnfused :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraphUnfused = compileRuntimeGraph

-- | Compile then run the Step-C single-edge fusion rewrite.
-- Equivalent to @'fuseRuntimeGraph' '<$>' 'compileRuntimeGraph'@.
-- Existing audio loaders use the unfused path; tests and future
-- fused-aware loaders call this entry point explicitly.
compileRuntimeGraphFused :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraphFused = fmap fuseRuntimeGraph . compileRuntimeGraph
