{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.IR
-- Description : Annotated intermediate representation
--
-- The first compilation pass: lower source graphs into an annotated IR carrying
-- rate and effect metadata.
--
-- See Note [Lowering as compilation] for how lowerGraph ties together
-- validation, sorting, annotation, and rate checking.
--
-- See Note [Surface syntax vs semantic syntax] in MetaSonic.Source for how this
-- module relates to the source DSL.

module MetaSonic.Bridge.IR
  ( -- * Symbolic IR types
    InputConn (..)
  , NodeIR (..)
  , GraphIR (..)
  , -- * Lowering from source
    lowerGraph
  , -- * Rate and effect inference
    inferRate
  , inferEff
  , -- * Rate validation
    checkRateEdges
  ) where

import           Control.DeepSeq           (NFData)
import qualified Data.Map.Strict           as M
import           GHC.Generics              (Generic)

import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

{- Note [IR vocabulary stripping]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The IR is the compiler's internal representation, stripped of the DSL vocabulary
(MetaSonic.Source) and supplemented with semantic annotations (MetaSonic.Types).

  Source type        IR type         Change
  ──────────────     ──────────     ──────────────────────
  Audio NodeID p     FromNode nid p  renamed; rate info moves
                                     to the node's irRate field
  Param Float        Literal Float   renamed
  UGen               NodeIR          annotated with Rate, [Eff]
  Connection         InputConn       uniform dependency/constant
  SynthGraph         GraphIR         nodes in execution order

The key difference: in the source graph, the fact that a connection is
"audio-rate" is encoded in the Connection constructor (Audio vs Param). In the
IR, rate information lives on the node itself (irRate), not on the connection.
This separation allows rate inference to be a node-level operation independent
of wiring, and allows future rate propagation to change a node's rate without
altering its input structure.

References are still symbolic (NodeID, not NodeIndex). The decisive
transformation to dense indices happens in MetaSonic.Compile. See Note [Dense
lowering] in MetaSonic.Compile.
-}

-- | An input connection in the IR: a symbolic reference to
-- another node's output, or a compile-time constant.
--
-- See Note [IR vocabulary stripping].
data InputConn
  = FromNode !NodeID !PortIndex
    -- ^ A dependency on another node's output port.
  | Literal  !Float
    -- ^ A compile-time constant. Carries no dependency.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A single node in the IR, carrying semantic annotations
-- that the source graph does not possess.
--
-- See Note [IR vocabulary stripping].
-- See Note [Rate inference vs rate propagation].
data NodeIR = NodeIR
  { irNodeID   :: !NodeID
  , irKind     :: !NodeKind
    -- ^ Dispatches to the correct C++ kernel.
    -- See Note [Adding a new node kind] in MetaSonic.Types.
  , irRate     :: !Rate
    -- ^ See Note [Rate inference vs rate propagation].
  , irEffects  :: ![Eff]
    -- ^ See Note [Resource effects] in MetaSonic.Types.
  , irInputs   :: ![InputConn]
    -- ^ The data dependency edges. Only FromNode entries
    -- create execution-order constraints.
  , irControls :: ![Float]
    -- ^ Default control values, sent to C++ at graph load
    -- time. Serve as fallbacks when no audio-rate input
    -- is connected.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

{- Note [Execution order invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Unlike the original monolithic code, where GraphIR stored
nodes in Map key order and a separate execution order list,
giNodes is now in topological (execution) order by
construction.

There is no separate giExecOrder field to get out of sync.
The list order IS the execution order.

This invariant is established by lowerGraph, which traverses
nodes in the order produced by validateAndSort (see
Note [Double-toposort fix] in MetaSonic.Validate), and must
be preserved by any downstream transformation that operates
on GraphIR.

See Note [Topological sort as compilation target] in
MetaSonic.Validate for how this order becomes the storage
order of the C++ runtime.
-}

-- | The graph IR: a list of 'NodeIR' in execution order.
--
-- See Note [Execution order invariant].
data GraphIR = GraphIR
  { giNodes :: ![NodeIR]
    -- ^ Nodes in execution order by construction. The list
    -- order must not be violated by downstream passes.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

{- Note [Rate inference vs rate propagation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Rate inference currently dispatches on NodeKind alone:

  SinOsc → SampleRate
  Out    → SampleRate
  Gain   → SampleRate

This is correct for the current node set but does not
propagate. A Gain node is unconditionally SampleRate even if
both its inputs are BlockRate.

The correct algorithm walks the graph bottom-up, computing
each node's rate as the join (maximum) of its input rates,
clamped to the node's intrinsic minimum rate. For example:

  - A SinOsc always has minimum rate SampleRate (it produces
    a sample-rate stream by definition)
  - A Gain has no intrinsic minimum rate; it inherits the
    rate of its inputs
  - An Out inherits from its input

This matters for region formation: if Gain is unconditionally
SampleRate, it can never be placed in a block-rate region,
even when that would be correct and more efficient.

See Note [Region rate compatibility] in MetaSonic.Compile.

Faust's semantic typing handles this through its "speed"
dimension, which propagates through the signal graph.
This is a key extension.
-}

-- | Infer the rate of a UGen from its kind.
--
-- See Note [Rate inference vs rate propagation].
inferRate :: UGen -> Rate
inferRate = \case
  SinOsc _ _ -> SampleRate
  Out _ _    -> SampleRate
  Gain _ _   -> SampleRate

-- | Infer the effect set of a UGen.
--
-- Currently all nodes are 'Pure'. When buses and buffers
-- become real shared resources, Out will carry
-- @BusWrite bus@, and a future In node will carry
-- @BusRead bus@.
--
-- See Note [Resource effects] in MetaSonic.Types.
inferEff :: UGen -> [Eff]
inferEff = \case
  SinOsc _ _ -> [Pure]
  Out _ _    -> [Pure]
  Gain _ _   -> [Pure]

{- Note [Rate edge validation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
At the semantic level, an audio-rate signal may be modeled as
a stream s : ℕ → ℝ, while a block-rate control signal may be
modeled as a function constant over each block: k : ℕ_B → ℝ.

The rate ordering is:

  CompileRate < InitRate < BlockRate < SampleRate

Reading "upward" in rate (block → sample) is safe: the
block-rate value is held constant over the faster time scale.
This is standard sample-and-hold semantics.

Reading "downward" in rate (sample → block) is unsafe without
explicit downsampling, because it requires choosing which
sample of the block to use — a semantic decision the compiler
should not make silently. checkRateEdges rejects such edges.

CompileRate is always safe as a source (it is the bottom of
the rate lattice — a compile-time constant can feed any rate).

This check makes the following proposition concrete:
Time is part of the type-theoretic and compilation story.

See Note [Rate discipline] in MetaSonic.Types.
-}

-- | Check that no edge violates the rate discipline.
-- A lower-rate node reading from a higher-rate node is an
-- error; the reverse is permitted (sample-and-hold).
--
-- See Note [Rate edge validation].
checkRateEdges :: M.Map NodeID NodeIR -> Either String ()
checkRateEdges nodeMap =
  mapM_ checkNode (M.elems nodeMap)
  where
    checkNode node =
      mapM_ (checkInput (irNodeID node) (irRate node)) (irInputs node)

    checkInput dstID dstRate (FromNode srcID _) =
      case M.lookup srcID nodeMap of
        Nothing -> Left $ "Missing source " ++ show srcID
                       ++ " for " ++ show dstID
        Just src
          | needsConversion (irRate src) dstRate ->
              Left $ "Rate mismatch: " ++ show srcID
                  ++ " (" ++ show (irRate src) ++ ") → "
                  ++ show dstID
                  ++ " (" ++ show dstRate ++ ")"
                  ++ " — downsampling requires explicit conversion"
          | otherwise -> Right ()
    checkInput _ _ (Literal _) = Right ()

    -- See Note [Rate edge validation].
    needsConversion srcRate dstRate =
      srcRate > dstRate && srcRate /= CompileRate

{- Note [Lowering as compilation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Central operation is:

  compile : SynthGraph → RuntimeProgram

This should not be understood as a single lowering pass. It
is a composition of semantic transformations. lowerGraph is
the first such transformation. It performs four operations:

  1. Validate and sort — via validateAndSort, a single
     traversal that checks referential integrity and
     produces execution order.
     See Note [Double-toposort fix] in MetaSonic.Validate.

  2. Lower vocabulary — strip UGen/Connection, produce
     NodeIR/InputConn.
     See Note [IR vocabulary stripping].

  3. Annotate — infer Rate and [Eff] for each node.
     See Note [Rate inference vs rate propagation].

  4. Validate rates — check that no edge violates the rate
     discipline.
     See Note [Rate edge validation].

The output is a GraphIR whose nodes are in execution order
and carry semantic metadata. Downstream passes (region
formation, dense compilation) consume this representation
without re-validating or re-sorting.

Note that step 1 traverses in execOrder (the topological
sort result), not in Map key order. This ensures giNodes is
in execution order by construction.
See Note [Execution order invariant].
-}

-- | Lower a source graph to the annotated IR. This is the
-- first real compilation pass.
--
-- See Note [Lowering as compilation].
lowerGraph :: SynthGraph -> Either String GraphIR
lowerGraph g = do
  -- Step 1: combined validation + topological sort
  -- See Note [Double-toposort fix] in MetaSonic.Validate.
  execOrder <- validateAndSort g

  let nodeMap = sgNodes g

  -- Step 2+3: lower each node in execution order, annotating
  -- with rate and effects.
  -- See Note [Execution order invariant].
  let !irNodes = map (lowerNode nodeMap) execOrder

  -- Step 4: validate rate discipline across edges.
  -- See Note [Rate edge validation].
  let !irMap = M.fromList [(irNodeID n, n) | n <- irNodes]
  checkRateEdges irMap

  pure GraphIR { giNodes = irNodes }

{- Note [Per-node lowering]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each NodeSpec is translated to a NodeIR by:

  1. inferKind — determine NodeKind from the UGen constructor
  2. inferRate — assign a Rate
     (see Note [Rate inference vs rate propagation])
  3. inferEff — assign an effect list
     (see Note [Resource effects] in MetaSonic.Types)
  4. lowerInputs — translate Connections to InputConns
  5. extractControls — extract default control values

Steps 4 and 5 together strip the DSL vocabulary:

  Audio nid port  →  FromNode nid port
  Param value     →  Literal value

For Param connections, extractControls also captures the
literal value as a control default. For Audio connections,
the default is 0.0 (the fallback when no input is connected
at runtime).

The error case in lowerNode (missing NodeID) should be
unreachable: validateAndSort has already checked referential
integrity. The error call is a defense against internal bugs
in the compiler, not against user errors.
-}

-- | Lower a single source node to an IR node.
--
-- See Note [Per-node lowering].
lowerNode :: M.Map NodeID NodeSpec -> NodeID -> NodeIR
lowerNode nodeMap nid =
  case M.lookup nid nodeMap of
    Nothing   -> error $ "lowerNode: missing " ++ show nid
                      ++ " (should be caught by validation)"
    Just spec ->
      let ugen = nsUgen spec
      in  NodeIR
            { irNodeID   = nid
            , irKind     = inferKind ugen
            , irRate     = inferRate ugen
            , irEffects  = inferEff ugen
            , irInputs   = lowerInputs ugen
            , irControls = extractControls ugen
            }

-- | Map a UGen constructor to its NodeKind tag.
--
-- See Note [Adding a new node kind] in MetaSonic.Types.
inferKind :: UGen -> NodeKind
inferKind = \case
  SinOsc _ _ -> KSinOsc
  Out _ _    -> KOut
  Gain _ _   -> KGain

-- | Lower UGen connections to IR InputConns.
--
-- See Note [IR vocabulary stripping].
lowerInputs :: UGen -> [InputConn]
lowerInputs = \case
  SinOsc freq phase -> [lowerConn freq, lowerConn phase]
  Out _ sig         -> [lowerConn sig]
  Gain sig amt      -> [lowerConn sig, lowerConn amt]

lowerConn :: Connection -> InputConn
lowerConn (Audio nid port) = FromNode nid port
lowerConn (Param x)        = Literal x

-- | Extract default control values from a UGen's
-- connections.
--
-- See Note [Per-node lowering].
extractControls :: UGen -> [Float]
extractControls = \case
  SinOsc freq phase -> [connDefault freq, connDefault phase]
  Out bus _         -> [fromIntegral bus]
  Gain _ amt        -> [connDefault amt]
  where
    connDefault (Param x)   = x
    connDefault (Audio _ _) = 0.0
