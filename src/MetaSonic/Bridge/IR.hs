{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.IR
-- Description : Annotated intermediate representation
--
-- The first compilation pass: lower source graphs into an annotated IR carrying
-- rate and effect metadata.

module MetaSonic.Bridge.IR
  ( -- * Symbolic IR types
    InputConn (..)
  , NodeIR (..)
  , GraphIR (..)
  , -- * Lowering from source
    lowerGraph
  , -- * Rate propagation
    propagateRates
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
  Param Double       Literal Double  renamed
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
  | Literal  !Double
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
  , irControls :: ![Double]
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
Rate assignment proceeds in two stages.

Stage 1 — kind-level minimum, in 'inferRate' (MetaSonic.Bridge.Source).
Each node receives a starting rate equal to 'ksRate' for its kind.
'ksRate' is interpreted as a *floor*, not as the final rate. The
split is:

  Producers / stateful kinds (floor SampleRate):
    SinOsc, SawOsc, PulseOsc, TriOsc, NoiseGen
      — generate sample-rate streams.
    LPF, HPF, BPF, Notch, Env, Delay, Smooth
      — carry per-sample or cross-block state.
    BusIn, BusInDelayed
      — read sample-rate bus storage.

  Consumers / stateless transforms (floor CompileRate):
    Gain, Add                — stateless arithmetic, no rate of own.
    Out, BusOut              — writers; the bus holds whatever rate
                               the writer contributes.

Stage 2 — propagation, in 'propagateRates' below. The graph is
walked in topological order (already established by 'topoSort'); each
node's final rate is

    irRate(n) = max (ksRate (kindOf n)) (max [ rate(in) | in <- inputs n ])

where the input rate of a 'FromNode src _' is the previously
computed 'irRate src' and the input rate of a 'Literal _' is
'CompileRate' (the lattice bottom).

Worked examples:

  * 'Gain (Param 0.5) (Param 0.3)'
      floor = CompileRate; inputs both CompileRate; final = CompileRate.
      The whole node is constant; a future optimization could fold it.

  * 'Gain o (Param 0.5)' where 'o' is a 'SinOsc'
      floor = CompileRate; inputs = [SampleRate, CompileRate];
      final = SampleRate. The Gain is lifted to match its sample-rate
      input.

  * 'SinOsc (Param 440) (Param 0)'
      floor = SampleRate; inputs both CompileRate; final = SampleRate.
      The floor wins; an oscillator with constant inputs is still
      sample-rate.

  * 'Out 0 (Param 0)'
      floor = CompileRate; input CompileRate; final = CompileRate.
      A silent / constant Out — currently still scheduled, but a
      future pass could elide it.

This matters for region formation: a graph mixing all-Param
subexpressions with sample-rate signal paths now produces distinct
regions instead of one degenerate sample-rate region. See Note
[Region rate compatibility] in "MetaSonic.Bridge.Compile".

The lattice is total: 'CompileRate < InitRate < BlockRate <
SampleRate' (see Note [Rate discipline] in "MetaSonic.Types"), so
'max' is well-defined. Propagation is monotone: a node's final rate
is always at least each of its inputs' rates and at least its kind
floor. Together with topological order, this guarantees that
'checkRateEdges' becomes vacuous post-propagation — every edge runs
"upward" in rate by construction. We keep the check as a defensive
post-condition.

Faust's semantic typing handles the same problem through its "speed"
dimension; MetaSonic's lattice and join is the same idea expressed
on a smaller, totally-ordered carrier set.
-}

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
  -- with kind floor rate and effects.
  -- See Note [Execution order invariant].
  let !irNodes0 = map (lowerNode nodeMap) execOrder

  -- Step 4: refine each node's irRate to the join of its inputs
  -- and its kind floor. Topological order makes this a single
  -- forward pass.
  -- See Note [Rate inference vs rate propagation].
  let !ir = propagateRates GraphIR { giNodes = irNodes0 }

  -- Step 5: validate rate discipline across edges. After
  -- propagation this should always succeed; we keep the check
  -- as a defensive post-condition.
  -- See Note [Rate edge validation].
  let !irMap = M.fromList [(irNodeID n, n) | n <- giNodes ir]
  checkRateEdges irMap

  pure ir

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

-- | Lower UGen connections to IR InputConns.
--
-- See Note [IR vocabulary stripping] and
-- Note [Uniform UGen view] in "MetaSonic.Bridge.Source".
lowerInputs :: UGen -> [InputConn]
lowerInputs = map lowerConn . uvInputs . ugenView

lowerConn :: Connection -> InputConn
lowerConn (Audio nid port) = FromNode nid port
lowerConn (Param x)        = Literal x

-- | Extract default control values from a UGen.
--
-- The control layout is per-kind and is given by 'uvControls'.
--
-- See Note [Per-node lowering] and
-- Note [Uniform UGen view] in "MetaSonic.Bridge.Source".
extractControls :: UGen -> [Double]
extractControls = uvControls . ugenView

-- | Propagate rates bottom-up through an already-lowered 'GraphIR'.
--
-- Each node's rate is replaced by
--
-- > max (kind floor) (max [ rate(input) | input <- inputs ])
--
-- where a 'FromNode' input contributes the source node's previously
-- computed rate and a 'Literal' input contributes 'CompileRate'.
--
-- Pre-conditions:
--
--   * 'giNodes' is in topological order. This holds whenever the
--     'GraphIR' came out of 'lowerGraph' (see Note [Execution order
--     invariant]).
--   * Each node's initial 'irRate' is the kind floor (set by
--     'lowerNode' via 'inferRate').
--
-- Post-condition: every node's 'irRate' is the join of its inputs'
-- rates and its kind floor. Idempotent: a second call returns the
-- same 'GraphIR'.
--
-- See Note [Rate inference vs rate propagation].
propagateRates :: GraphIR -> GraphIR
propagateRates ir =
  -- foldl' (strict left fold) avoids accumulating thunks in the rate
  -- map across long graphs.
  let (_finalRates, revRefined) = foldl' step (M.empty, []) (giNodes ir)
  in  ir { giNodes = reverse revRefined }
  where
    -- The accumulator carries the rate of every node visited so far
    -- (rates) and the refined nodes in reverse order (revRefined).
    -- Topological order guarantees that every 'FromNode' input has
    -- already been visited when we refine the current node.
    step (!rates, acc) node =
      let inputRates  = map (inputRate rates) (irInputs node)
          -- 'irRate node' here is the kind floor from 'lowerNode'.
          -- 'maximum' is partial in general but the list always has
          -- at least 'irRate node', so the call is total here.
          !refined    = maximum (irRate node : inputRates)
          !node'      = node { irRate = refined }
          !rates'     = M.insert (irNodeID node) refined rates
      in (rates', node' : acc)

    -- Lookups should never fail under the topological-order
    -- precondition; missing source is an internal bug, not user
    -- error.
    inputRate rates (FromNode src _) =
      case M.lookup src rates of
        Just r  -> r
        Nothing -> error $
          "propagateRates: unresolved source " ++ show src
            ++ " (giNodes is not in topological order)"
    inputRate _     (Literal _)      = CompileRate
