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
  , -- * Dependency derivation (useful for testing the scheduler)
    busEdges
  , effectiveDeps
  ) where

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

{- Note [Effect-induced edges (E_r)]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Why this pass exists, in one paragraph: 'BusOut n' and 'BusIn n' (and 'Out',
which writes to a hardware-routed bus the same way 'BusOut' writes to a
plain bus) interact through a *shared resource* — the bus, identified by an
integer. There is no structural 'Audio' edge between a writer and a reader;
they are connected only by the fact that they name the same bus number. So
the structural dependency graph alone (E_s, what 'dependencies' returns)
does not constrain their execution order. Topological sort over E_s alone
could schedule a 'BusIn 5' before any 'BusOut 5' on the same bus, and the
reader would see a zero-cleared bus instead of the live signal it expects.

The 'Eff' type was designed for exactly this: every node carries an effect
annotation ('BusWrite n', 'BusRead n', 'BusReadDelayed n', 'BufRead n',
'BufWrite n', or 'Pure'), and the *semantically schedulable* graph is

    G* = (N, E_s ∪ E_r ∪ E_t)

where E_s are structural edges (audio connections), E_r are
resource-induced edges derived from effects, and E_t are temporal /
rate-boundary edges. (E_t is future work; we only deal with E_s and E_r
today.)

This pass derives E_r:

  - For every node, ask 'inferEff' for its effect annotations.
  - For every pair (writer with 'BusWrite n', *live* reader with
    'BusRead n') on the same bus number, emit edge writer → reader.
  - Merge those edges into the dependency map used by 'topoSort'.

That's it. The topological sort then operates over G* = E_s ∪ E_r and
produces an ordering that respects both kinds of dependencies. Cycle
detection works uniformly: a graph that creates a cycle through buses
(e.g. 'BusIn 5' → ... → 'BusOut 5') is rejected by the same cycle detector
that rejects structural cycles.

Same-cycle semantics for 'BusRead'. A 'BusIn n' always reads the live,
accumulated value because it is forced to follow every 'BusOut n' on the
same bus in the same block.

Cross-cycle semantics for 'BusReadDelayed' — feedback. 'BusInDelayed n'
carries 'BusReadDelayed n', and this pass *deliberately* does not pair
'BusReadDelayed' with 'BusWrite'. The reader is reading the *previous
block's* snapshot of bus n, which by definition is not modified by any
node executing in the current block. Two consequences:

  1. A 'BusInDelayed n' may sit anywhere in the topological order
     relative to a 'BusOut n' — including *before* it. This is what
     makes feedback loops schedulable: the cycle that closes through
     'BusInDelayed → ... → BusOut' has no E_r edge to pair with the
     structural edges, so it is not a cycle in G* at all. The only
     "cycle" is across blocks, broken by the runtime's swap of the
     bus pool's snapshot and live buffers.
  2. 'BusInDelayed' on a bus with no writer is well-defined: the
     snapshot stays at the zero-initialized state and the read produces
     silence — same as 'BusIn' on an unwritten bus.

The asymmetric treatment of 'BusRead' vs 'BusReadDelayed' is the central
abstraction that lets the same scheduler accept both same-cycle routing
graphs and feedback graphs without runtime graph rewriting or implicit
delays. In SuperCollider terms, 'BusRead' is 'In.ar' and 'BusReadDelayed'
is 'InFeedback.ar'.

Why the codebase uses E_r rather than runtime phasing (e.g. "run all
BusOut nodes first, then everything else"): runtime phasing fails on
chained buses (a node that reads bus A and writes bus B), recreates the
same dependency analysis at a different layer, and doesn't compose with
region formation or a future scheduler. E_r is the abstraction the
codebase has been building toward since 'Eff' was introduced; this pass
just connects two notes that were sitting next to each other.

See also: Note [Resource effects] in "MetaSonic.Types", Note [Bus model:
SC-style same-cycle audio buses] in "MetaSonic.Bridge.Source", Note
[Effects are per-UGen, not per-kind] in "MetaSonic.Bridge.Source", and
Note [Bus pool double-buffering] in @tinysynth/rt_graph.cpp@ for the
runtime-side ping-pong that realizes the snapshot semantics.
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

-- | Pairs (writer, reader) for every same-bus 'BusWrite' / 'BusRead' effect
-- in the graph. These are the E_r edges that augment the structural
-- dependency map before topological sort.
--
-- Only the *live* reader effect 'BusRead' is paired here.
-- 'BusReadDelayed' (carried by 'BusInDelayed') is intentionally
-- excluded: a delayed reader targets the *previous* block's snapshot
-- of the bus, which the current block's writers cannot mutate, so
-- there is no execution-order constraint between them. Excluding
-- delayed readers from E_r is what makes feedback loops schedulable —
-- see Note [Effect-induced edges (E_r)] for the rationale.
--
-- 'BusOut n' produces 'BusWrite n' via 'inferEff' and 'BusIn n'
-- produces 'BusRead n'; this function pairs them up by bus number so
-- the scheduler sees an explicit writer → reader edge.
--
-- See Note [Effect-induced edges (E_r)].
busEdges :: SynthGraph -> [(NodeID, NodeID)]
busEdges g =
  let nodes   = M.toList (sgNodes g)
      writers = [ (nid, n)
                | (nid, ns) <- nodes
                , BusWrite n <- inferEff (nsUgen ns) ]
      readers = [ (nid, n)
                | (nid, ns) <- nodes
                , BusRead  n <- inferEff (nsUgen ns) ]
                    -- BusReadDelayed is *not* listed: it must not
                    -- contribute to E_r. See Note [Effect-induced
                    -- edges (E_r)].
  in [ (w, r) | (w, bw) <- writers, (r, br) <- readers, bw == br ]

-- | The effective dependency map used by topological sort: the structural
-- graph (E_s) merged with the resource-induced edges (E_r) returned by
-- 'busEdges'.
--
-- Reader-keyed: @effectiveDeps g ! reader@ gives every node that must
-- execute before @reader@ — both structural producers and same-bus
-- writers.
--
-- See Note [Effect-induced edges (E_r)].
effectiveDeps :: SynthGraph -> M.Map NodeID [NodeID]
effectiveDeps g =
  foldr addBusEdge structural (busEdges g)
  where
    structural = M.map (dependencies . nsUgen) (sgNodes g)
    addBusEdge (writer, reader) = M.insertWith (++) reader [writer]

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

The dependency adjacency map (depMap) is 'effectiveDeps': it merges the
structural edges (E_s, from 'dependencies') with the resource-induced
edges (E_r, from 'busEdges'). The toposort therefore respects both kinds
of dependency uniformly. Cycles in either set — or cycles that span both —
are caught by the same back-edge detection.

See Note [Effect-induced edges (E_r)] for what E_r contributes and why.
-}

-- | Produce a topological ordering of 'NodeID's, or fail
-- with a cycle diagnostic.
--
-- The dependency map consumed here is 'effectiveDeps' — structural
-- edges plus resource-induced E_r edges from same-bus 'BusWrite' /
-- 'BusRead' pairs. A 'BusOut n' always appears before any 'BusIn n'
-- in the result.
--
-- See Note [Toposort algorithm].
-- See Note [Topological sort as compilation target].
-- See Note [Effect-induced edges (E_r)].
topoSort :: SynthGraph -> Either String [NodeID]
topoSort g = do
  (_, _, order) <- foldlM visit (S.empty, S.empty, []) (M.keys (sgNodes g))
  pure (reverse order)
  where
    -- Pre-compute the augmented dependency map once: structural deps
    -- plus E_r edges from bus writers/readers.
    depMap :: M.Map NodeID [NodeID]
    !depMap = effectiveDeps g

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
