{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : MetaSonic.Validate
-- Description : Structural validation and topological ordering
--
-- Validation is the gate between graph construction and
-- compilation: a graph that passes validation can be compiled;
-- a graph that fails cannot. No invalid structure should ever
-- reach the runtime.
--
-- See Note [Structural vs semantic well-formedness] for what
-- this module checks and what it deliberately leaves to later
-- passes.
--
-- See Note [Topological sort as compilation target] for how the
-- sort computed here becomes the storage order of the C++
-- runtime.

module MetaSonic.Bridge.Validate
  ( -- * Combined validation + ordering
    validateAndSort
  , -- * Individual passes (useful for testing)
    checkDependencies
  , topoSort
  ) where

import           Control.Monad           (mapM_)
import           Data.Foldable           (foldlM)
import qualified Data.Map.Strict         as M
import qualified Data.Set                as S

import           MetaSonic.Bridge.Source
import           MetaSonic.Types

{- Note [Structural vs semantic well-formedness]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This module enforces two structural well-formedness conditions:

  1. Referential integrity: every NodeID referenced by a
     Connection must exist in the graph. A dangling reference
     is a compilation error. Checked by checkDependencies.

  2. Acyclicity: the explicit dependency graph must be a DAG.
     A cycle is a compilation error. Checked by topoSort.

Structural validation is necessary but not sufficient for
semantic well-formedness. The following conditions are checked
or will be checked by later passes:

  - Rate mismatches requiring conversion nodes.
    Checked by checkRateEdges in MetaSonic.IR.
    See Note [Rate discipline] in MetaSonic.Types.

  - Implicit resource dependencies not represented by graph
    edges. Future: effect analysis using Eff annotations.
    See Note [Resource effects] in MetaSonic.Types.

  - Recursive definitions whose state semantics must be made
    explicit. Future: delay semantics. The current prototype
    requires strict acyclicity.

  - One-sided dependencies from analysis or recorder nodes.
    Future: satellite edge insertion, following SuperNova's
    design.

The separation is intentional: structural checks are cheap and
catch the most common errors early. Semantic checks require
annotation (rates, effects) that does not exist until after
lowering in MetaSonic.IR.
-}

{- Note [Topological sort as compilation target]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The topological sort establishes execution order. After this
pass, every node has a fixed position in the evaluation
sequence, and that sequence respects all explicit data
dependencies.

This list becomes the storage order of the dense runtime array
in C++, via the following chain:

  topoSort
    → giNodes in MetaSonic.IR (list order = execution order)
    → compileRuntimeGraph in MetaSonic.Compile (NodeID → NodeIndex)
    → loadRuntimeGraph in MetaSonic.FFI (adds nodes in order)
    → rt_graph_process in rt_graph.cpp (iterates in storage order)

SuperNova identifies sequential linearized traversal as
efficient for fine-grained graphs in the sequential case.
MetaSonic treats this not as a convenient implementation
shortcut but as the desired target of compilation. The sort
computed here is the origin of that linearization.

See Note [Dense lowering] in MetaSonic.Compile.
-}

{- Note [Double-toposort fix]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The original monolithic code had a double-toposort bug:
validateGraph called topoSort internally to check for cycles
(discarding the result), then lowerGraph called topoSort again
to get the execution order. Three traversals for one result.

validateAndSort computes both checks in a single traversal:
checkDependencies verifies referential integrity, then topoSort
verifies acyclicity and produces the execution order. The
result is threaded forward to lowerGraph in MetaSonic.IR, which
uses it directly without re-sorting.
-}

-- | Verify that every 'NodeID' referenced by a 'Connection'
-- exists in the graph. Returns 'Left' with a diagnostic on
-- the first missing dependency.
--
-- See Note [Structural vs semantic well-formedness].
checkDependencies :: SynthGraph -> Either String ()
checkDependencies g =
  mapM_ checkNode (M.elems (sgNodes g))
  where
    checkNode spec =
      mapM_ checkDep (dependencies (nsUgen spec))

    checkDep nid
      | M.member nid (sgNodes g) = Right ()
      | otherwise = Left $ "Missing dependency: " ++ show nid

{- Note [Toposort algorithm]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The sort is a depth-first search with temporary and permanent
mark sets, following Tarjan's algorithm:

  - Temporary marks detect back edges (cycles). If we visit a
    node that is already temporarily marked, we have found a
    cycle and report an error.

  - Permanent marks record fully visited nodes. If we visit a
    node that is already permanently marked, we skip it.

  - On first visit, we temporarily mark the node, recurse into
    all its dependencies, then remove the temporary mark, add
    a permanent mark, and append the node to the accumulator.

The accumulator is built in reverse; the final result is
reversed to produce execution order (dependencies before
dependents).

The dependency adjacency map (depMap) is pre-computed once
from the SynthGraph to avoid repeated traversal of UGen
constructors during the DFS.
-}

-- | Produce a topological ordering of 'NodeID's, or fail
-- with a cycle diagnostic.
--
-- See Note [Toposort algorithm].
-- See Note [Topological sort as compilation target].
topoSort :: SynthGraph -> Either String [NodeID]
topoSort g = do
  (_, _, order) <- foldlM visit (S.empty, S.empty, []) (M.keys (sgNodes g))
  pure (reverse order)
  where
    -- Pre-compute the dependency adjacency map once.
    depMap :: M.Map NodeID [NodeID]
    !depMap = M.map (dependencies . nsUgen) (sgNodes g)

    visit
      :: (S.Set NodeID, S.Set NodeID, [NodeID])
      -> NodeID
      -> Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    visit (temp, perm, acc) nid = go temp perm acc nid

    go :: S.Set NodeID   -- temporary marks (currently visiting)
       -> S.Set NodeID   -- permanent marks (fully visited)
       -> [NodeID]       -- accumulator (reverse execution order)
       -> NodeID         -- current node
       -> Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    go !temp !perm !acc nid
      | nid `S.member` perm = Right (temp, perm, acc)
      | nid `S.member` temp = Left $ "Cycle detected at " ++ show nid
      | otherwise =
          case M.lookup nid depMap of
            Nothing -> Left $ "Unknown node in topoSort: " ++ show nid
            Just ds -> do
              let !temp' = S.insert nid temp
              (temp'', perm', acc') <-
                foldlM (\(t, p, a) d -> go t p a d)
                       (temp', perm, acc)
                       ds
              let !tempFinal = S.delete nid temp''
                  !permFinal = S.insert nid perm'
              pure (tempFinal, permFinal, nid : acc')

-- | Check referential integrity and produce a topological
-- execution order in one pass. This is the entry point used
-- by 'MetaSonic.IR.lowerGraph'.
--
-- See Note [Double-toposort fix].
validateAndSort :: SynthGraph -> Either String [NodeID]
validateAndSort g = do
  checkDependencies g
  topoSort g
