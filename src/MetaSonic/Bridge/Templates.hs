{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}

-- |
-- Module      : MetaSonic.Bridge.Templates
-- Description : Inter-template ordering from bus dataflow
--
-- One pipeline stage above 'MetaSonic.Bridge.Compile'. Where
-- 'Compile' produces a dense per-template 'RuntimeGraph', this module
-- composes several templates into a 'TemplateGraph': an ordered list
-- of templates plus the precedence DAG that the compiler decreed by
-- analyzing each template's bus reads/writes.
--
-- The whole module exists to keep execution order on the Haskell side
-- at compile time, the way intra-graph ordering already is. The
-- runtime stays a dumb executor: it iterates templates in the order
-- it was handed and never reorders. Users do not get SC-style live
-- 'head'/'tail'/'before'/'after' ordering primitives — instead, they
-- write bus connectivity, and 'compileTemplateGraph' derives the
-- order from the dataflow.
--
-- See Note [Template-level precedence from bus dataflow].

module MetaSonic.Bridge.Templates
  ( -- * Identifiers
    TemplateID (..)
  , -- * Per-template metadata
    BusFootprint (..)
  , emptyFootprint
  , busFootprint
  , -- * §6.C.4 resource footprints (bus + buffer)
    BufferFootprint (..)
  , emptyBufferFootprint
  , ResourceFootprint (..)
  , emptyResourceFootprint
  , resourceFootprint
  , Template (..)
  , -- * Compile-decreed plan
    TemplateGraph (..)
  , compileTemplateGraph
  , compileTemplateGraphFused
  , -- * §6.C.4 precedence rule (exposed for tests)
    computePrecedence
  , templatePrecedes
  , -- * Template-level schedule stats (§4.E.2c read-only view)
    TemplateScheduleStats (..)
  , templateScheduleStats
  ) where

import           Control.DeepSeq             (NFData)
import           Data.Foldable               (foldlM)
import           Data.List                   (intercalate, partition)
import qualified Data.Map.Strict             as M
import qualified Data.Set                    as S
import           GHC.Generics                (Generic)

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types


{- Note [Template-level precedence from bus dataflow]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The intra-graph scheduler already derives execution order from data
dependencies: structural edges (E_s) plus resource-induced edges
(E_r) from same-bus 'BusWrite' / 'BusRead' pairs. This module is
that idea applied one tier up.

Each template exposes a 'BusFootprint': the set of bus indices it
writes (via 'Out' or 'BusOut'), the set it reads live (via 'BusIn'),
and the set it reads delayed (via 'BusInDelayed'). The 'Eff' machinery
already classifies these uniformly — see Note [Effects are per-UGen,
not per-kind] in "MetaSonic.Bridge.Source" — so footprint extraction
is a single fold over 'irEffects'.

Precedence between two templates @T_a@ and @T_b@:

  T_a precedes T_b   iff   bfWrites(T_a) ∩ bfReads(T_b) ≠ ∅

That is: if @T_b@ reads, in this block, a bus that @T_a@ writes, then
@T_a@ must run first. This is the inter-template counterpart of E_r.
'BusReadDelayed' deliberately does not contribute, exactly as within a
single graph — see Note [Effect-induced edges (E_r)] in
"MetaSonic.Bridge.Validate" — so cross-template feedback through
'BusInDelayed' stays schedulable.

A cycle in the precedence DAG is a compile error. The remedy is the
same as within a graph: replace one of the live reads in the cycle
with a delayed read.

Operationally, the C++ runtime will iterate templates in the order
this module produces and run every instance of each template before
moving on. Within a template, instances run in insertion order; cross-
instance ordering is determined entirely by template-level precedence.
This is the "groups exist, but as a derivation, not a primitive" model
— see the project memory entry for why metasonic deliberately rejects
SC's runtime ordering primitives.
-}

-- | A dense template identifier, parallel to 'NodeIndex'. Storage
-- order in 'tgTemplates' equals execution order; 'TemplateID i' is
-- the element at position @i@.
newtype TemplateID = TemplateID Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

{- Note [Bus footprint surface]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'BusFootprint' is the public bus-level interface a template exposes
to its peers: which buses it touches, and how. The fold that builds
it ('busFootprint') reads only 'irEffects' — never inspects node
kinds or controls — so any future 'Eff' constructor that names a bus
('BufRead'/'BufWrite' on a shared buffer, etc.) is one pattern-match
away from contributing to template-level precedence.

The three sets are deliberately disjoint in role even though the same
bus number can appear in more than one. A template that does 'BusOut
5' followed by 'BusInDelayed 5' is a valid self-feedback shape and
contributes both to 'bfWrites' and to 'bfDelayedReads' on bus 5; only
'bfWrites' is consulted when computing precedence against peers.
-}

-- The 'BusFootprint' type and 'emptyFootprint' helper are defined in
-- 'MetaSonic.Bridge.Compile' so the same shape can be reused at
-- whole-template, per-region, and per-node scope (see Note [Bus
-- footprints, template- vs region-level] in Compile). They are
-- re-exported from this module for the existing public surface.

-- | Extract a 'BusFootprint' from a lowered 'GraphIR'.
--
-- Reads only 'irEffects'. The fold is order-independent.
--
-- See Note [Bus footprint surface]. §6.C.4 generalizes this to
-- 'resourceFootprint' which also records 'BufRead' / 'BufWrite'
-- effects; 'busFootprint' is the bus-only projection retained
-- for callers that only need bus precedence.
busFootprint :: GraphIR -> BusFootprint
busFootprint ir = foldr stepNode emptyFootprint (giNodes ir)
  where
    stepNode n acc = foldr addEff acc (irEffects n)
    addEff (BusWrite        b) fp = fp { bfWrites       = S.insert b (bfWrites fp) }
    addEff (BusRead         b) fp = fp { bfReads        = S.insert b (bfReads fp) }
    addEff (BusReadDelayed  b) fp = fp { bfDelayedReads = S.insert b (bfDelayedReads fp) }
    addEff _                   fp = fp

-- | §6.C.4 extractor: derive the full 'ResourceFootprint' (bus
-- *and* buffer fields) from a lowered 'GraphIR'. Reads only
-- 'irEffects'. The fold is order-independent.
--
-- In 6.C.4 only the bus half participates in the precedence
-- rule until slice 3 unions in the buffer edges; the buffer
-- half is populated but not consumed yet, which keeps
-- bus-only graphs bit-identical with slice 1 / 2.
--
-- See Note [Resource footprints, §6.C.4] in
-- 'MetaSonic.Bridge.Compile.Types'.
resourceFootprint :: GraphIR -> ResourceFootprint
resourceFootprint ir = foldr stepNode emptyResourceFootprint (giNodes ir)
  where
    stepNode n acc = foldr addEff acc (irEffects n)
    addEff (BusWrite        b) fp = fp
      { rfBuses = (rfBuses fp) { bfWrites       = S.insert b (bfWrites       (rfBuses fp)) } }
    addEff (BusRead         b) fp = fp
      { rfBuses = (rfBuses fp) { bfReads        = S.insert b (bfReads        (rfBuses fp)) } }
    addEff (BusReadDelayed  b) fp = fp
      { rfBuses = (rfBuses fp) { bfDelayedReads = S.insert b (bfDelayedReads (rfBuses fp)) } }
    addEff (BufWrite        b) fp = fp
      { rfBuffers = (rfBuffers fp) { bfBufWrites       = S.insert b (bfBufWrites       (rfBuffers fp)) } }
    addEff (BufRead         b) fp = fp
      { rfBuffers = (rfBuffers fp) { bfBufReads        = S.insert b (bfBufReads        (rfBuffers fp)) } }
    addEff Pure                fp = fp

-- | A single template — one 'RuntimeGraph' plus the resource
-- interface it exposes (buses + buffers, §6.C.4). The 'tplName'
-- is user-provided and used only for error messages and
-- diagnostics; uniqueness is enforced by
-- 'compileTemplateGraph'.
data Template = Template
  { tplID        :: !TemplateID
  , tplName      :: !String
  , tplGraph     :: !RuntimeGraph
  , tplFootprint :: !ResourceFootprint
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

{- Note [TemplateGraph as the compile-decreed plan]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'TemplateGraph' is to 'RuntimeGraph' what 'RuntimeGraph' is to
'NodeIR': a dense, ordered, precedence-annotated structure ready to
be transferred across an FFI boundary.

Storage order in 'tgTemplates' equals execution order. The runtime
will iterate templates left-to-right and run every instance of each
template before moving on. 'tgPrecedence' is a reader-keyed dependency
map ('reader → set of writers that must precede it'), retained for
diagnostics, future region-DAG-style scheduling, and optional
incremental recompilation.

The 'TemplateID' assigned to each template is its position in the
input list, *not* its position in 'tgTemplates' — that way callers can
reference a template by the ID they constructed it with even if the
topological sort permuted the order. Callers that want a stable,
content-addressed ID should hash the template themselves.
-}

-- | The fully-compiled template plan: templates in execution order
-- plus the precedence DAG used to derive that order.
--
-- See Note [TemplateGraph as the compile-decreed plan].
data TemplateGraph = TemplateGraph
  { tgTemplates  :: ![Template]
    -- ^ Templates in execution order.
  , tgPrecedence :: !(M.Map TemplateID (S.Set TemplateID))
    -- ^ Reader-keyed: @tgPrecedence ! reader@ is every template that
    -- must execute before @reader@. A template absent from the map
    -- has no predecessors.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

{- Note [compileTemplateGraph stages]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The function runs four stages, each of which can fail with a
diagnostic:

  1. Per-template lowering: each '(name, SynthGraph)' pair runs
     through 'lowerGraph' and 'compileRuntimeGraph'. A failure here is
     a single-template compile error; it is reported with the template
     name to disambiguate.

  2. Name uniqueness check. Templates are referenced by name in
     diagnostics; collisions would make error messages ambiguous.

  3. Precedence derivation: pairwise intersection of writes against
     live reads. O(N²) in the number of templates, which is fine — N
     is small (a typical synth ensemble has < 100 templates).

  4. Topological sort: DFS with cycle detection over the precedence
     DAG. Cycles are reported with the offending template names and
     the bus indices that closed the loop.
-}

-- | Compile a list of named source graphs into a 'TemplateGraph'.
--
-- See Note [compileTemplateGraph stages].
compileTemplateGraph
  :: [(String, SynthGraph)]
  -> Either String TemplateGraph
compileTemplateGraph entries = do
  -- Stage 1: per-template lowering. The 'TemplateID' is the input
  -- position so callers can reference templates by construction order
  -- regardless of the final execution order.
  templates <- mapM compileOne (zip [0..] entries)

  -- Stage 2: name uniqueness.
  checkUniqueNames templates

  -- Stage 3: precedence DAG.
  let !precedence = computePrecedence templates

  -- Stage 4: topological sort.
  ordered <- topoSortTemplates templates precedence

  pure TemplateGraph
    { tgTemplates  = ordered
    , tgPrecedence = precedence
    }
  where
    compileOne :: (Int, (String, SynthGraph)) -> Either String Template
    compileOne (i, (name, sg)) = do
      ir <- prefixError name (lowerGraph sg)
      rg <- prefixError name (compileRuntimeGraph ir)
      let !fp = resourceFootprint ir
      pure Template
        { tplID        = TemplateID i
        , tplName      = name
        , tplGraph     = rg
        , tplFootprint = fp
        }

    prefixError :: String -> Either String a -> Either String a
    prefixError name (Left err) = Left $ "template " <> show name <> ": " <> err
    prefixError _    (Right x)  = Right x

-- | Step C sibling of 'compileTemplateGraph'. Each template's
-- 'tplGraph' is produced by 'compileRuntimeGraphFused', so the
-- resulting 'TemplateGraph' carries 'RFused' inputs and 'rnElided'
-- nodes wherever the single-edge Gain rewrite applies. Stages 2–4
-- (name uniqueness, precedence DAG, topo sort) are unchanged — fusion
-- does not touch effect annotations or bus footprints.
--
-- This is the constructor that 'loadTemplateGraphFused' is designed
-- to consume; passing it to 'loadTemplateGraph' (the unfused loader)
-- raises the documented fail-fast error.
compileTemplateGraphFused
  :: [(String, SynthGraph)]
  -> Either String TemplateGraph
compileTemplateGraphFused entries = do
  templates <- mapM compileOneFused (zip [0..] entries)
  checkUniqueNames templates
  let !precedence = computePrecedence templates
  ordered <- topoSortTemplates templates precedence
  pure TemplateGraph
    { tgTemplates  = ordered
    , tgPrecedence = precedence
    }
  where
    compileOneFused :: (Int, (String, SynthGraph)) -> Either String Template
    compileOneFused (i, (name, sg)) = do
      ir <- prefixError name (lowerGraph sg)
      rg <- prefixError name (compileRuntimeGraphFused ir)
      let !fp = resourceFootprint ir
      pure Template
        { tplID        = TemplateID i
        , tplName      = name
        , tplGraph     = rg
        , tplFootprint = fp
        }

    prefixError :: String -> Either String a -> Either String a
    prefixError name (Left err) = Left $ "template " <> show name <> ": " <> err
    prefixError _    (Right x)  = Right x

checkUniqueNames :: [Template] -> Either String ()
checkUniqueNames ts =
  let names    = map tplName ts
      seen     = foldr (\n acc -> M.insertWith (+) n (1 :: Int) acc) M.empty names
      dupes    = [ n | (n, c) <- M.toList seen, c > 1 ]
  in case dupes of
       []  -> Right ()
       ns  -> Left $ "duplicate template name(s): "
                  <> intercalate ", " (map show ns)

-- | Build the reader-keyed precedence map: for each template @b@, the
-- set of templates @a@ such that @a@'s writes intersect @b@'s live
-- reads.
--
-- Quadratic in the number of templates, which is fine — template
-- counts are tiny.
computePrecedence :: [Template] -> M.Map TemplateID (S.Set TemplateID)
computePrecedence ts = M.fromList
  [ ( tplID b
    , S.fromList
        [ tplID a
        | a <- ts
        , tplID a /= tplID b
        , templatePrecedes (tplFootprint a) (tplFootprint b)
        ]
    )
  | b <- ts
  ]

-- | §6.C.4 slice 3 precedence rule: A precedes B iff A writes
-- some resource (bus or buffer) that B reads live. Bus and
-- buffer id spaces are disjoint, so checking the two
-- intersections separately avoids any namespace collision and
-- keeps the rule shape identical to the pre-§6.C.4 bus-only
-- form.
--
-- Delayed reads (bus or buffer) do not contribute — matches the
-- pre-§6.C.4 rule and the intra-graph E_r convention.
--
-- Writer kinds for buffers don't exist yet (6.C.4 follow-up
-- adds RecordBufMono), so the buffer half of the disjunction is
-- always False in v1 corpora — which is what keeps bus-only
-- precedence bit-identical with slice 2.
templatePrecedes :: ResourceFootprint -> ResourceFootprint -> Bool
templatePrecedes a b = busEdge || bufEdge
  where
    busEdge = not (S.null
      (bfWrites (rfBuses a) `S.intersection`
       bfReads  (rfBuses b)))
    bufEdge = not (S.null
      (bfBufWrites (rfBuffers a) `S.intersection`
       bfBufReads  (rfBuffers b)))


{- Note [Template topo-sort]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The same DFS-with-marks pattern as 'topoSort' in
"MetaSonic.Bridge.Validate", but operating on the inter-template
precedence map instead of the intra-graph dependency map. Cycles are
reported with the chain of template names and the buses that made each
link.

Diagnostic shape: "cycle: A → B → A on bus 5". The user's remedy is to
replace one of the live reads in the cycle with a delayed read,
exactly as within a single graph.
-}

-- | Topologically sort templates by precedence. Cycles → error.
topoSortTemplates
  :: [Template]
  -> M.Map TemplateID (S.Set TemplateID)
  -> Either String [Template]
topoSortTemplates ts precedence = do
  let !idToTemplate = M.fromList [ (tplID t, t) | t <- ts ]
  (_, _, order) <-
    foldlM visit (S.empty, S.empty, []) (map tplID ts)
  pure $ map (idToTemplate M.!) (reverse order)
  where
    visit
      :: (S.Set TemplateID, S.Set TemplateID, [TemplateID])
      -> TemplateID
      -> Either String (S.Set TemplateID, S.Set TemplateID, [TemplateID])
    visit (temp, perm, acc) tid = go temp perm acc tid

    go !temp !perm !acc tid
      | tid `S.member` perm = Right (temp, perm, acc)
      | tid `S.member` temp =
          Left $ "template precedence cycle at "
              <> templateName tid
      | otherwise =
          let !temp'  = S.insert tid temp
              !preds  = M.findWithDefault S.empty tid precedence
          in do
            (temp'', perm', acc') <-
              foldlM (\(t, p, a) d -> go t p a d)
                     (temp', perm, acc)
                     (S.toList preds)
            let !tempFinal = S.delete tid temp''
                !permFinal = S.insert tid perm'
            pure (tempFinal, permFinal, tid : acc')

    templateName tid =
      case [ tplName t | t <- ts, tplID t == tid ] of
        (n : _) -> show n
        []      -> show tid

-- | Read-only ensemble-level schedule view used by the
-- '--fusion-survey' parallel-readiness section. Pairs the
-- template-precedence DAG width with the per-template aggregate
-- produced by 'addScheduleStats'.
--
-- The precedence-layer width is the natural cross-template analogue
-- of 'rssMaxFreeLayerWidth' inside a single graph: how many templates
-- land at the same topological layer of 'tgPrecedence' — i.e. have no
-- precedence dependency on each other through bus dataflow. Width 1
-- means templates form a precedence chain; width @>= 2@ means the
-- precedence DAG has candidate cross-template surface area even when
-- each template is internally barrier-dominated.
--
-- This is /template precedence width/, not direct schedulable
-- parallelism. Two templates at the same layer may still both write
-- the same bus (no read-after-write between them, but a write-write
-- conflict on shared state). Actually executing them concurrently
-- would require either per-worker bus accumulation with a
-- deterministic reduction step, or serialization of conflicting
-- writers. Designing that policy is out of scope for this descriptive
-- stat.
--
-- The runnable/reduction fields split that ambiguity without choosing
-- a policy: a full template layer with no shared writes contributes
-- to 'tssMaxTemplateRunnableWidth'; a full layer with at least one
-- shared-write hazard contributes to 'tssMaxTemplateReductionWidth'.
--
-- The C++ side still walks templates in their compile-decreed
-- @tgTemplates@ order; nothing currently consumes the layer width.
data TemplateScheduleStats = TemplateScheduleStats
  { tssTemplateCount         :: !Int
    -- ^ Total templates in the ensemble.
  , tssMaxTemplateLayerWidth :: !Int
    -- ^ Max count of templates at any topological layer of
    -- 'tgPrecedence' (template precedence width). Candidate
    -- cross-template surface area, not directly schedulable
    -- parallelism — see 'TemplateScheduleStats'.
  , tssSharedWriteHazards    :: !Int
    -- ^ Count of same-layer same-bus write conflicts across all
    -- template precedence layers.
  , tssMaxTemplateRunnableWidth
                              :: !Int
    -- ^ Widest full template layer with no shared-write hazards:
    -- runnable without deterministic reduction.
  , tssMaxTemplateReductionWidth
                              :: !Int
    -- ^ Widest full template layer that has at least one shared-write
    -- hazard: candidate width that needs a deterministic reduction or
    -- serialization policy.
  , tssAggregate             :: !RegionScheduleStats
    -- ^ Per-template stats combined via 'addScheduleStats' (counts
    -- add; widths take the max).
  } deriving stock (Eq, Show)

-- | Compute 'TemplateScheduleStats' for an ensemble. Forwards any
-- per-template 'regionScheduleStats' diagnostic on @Left@ so a
-- malformed template propagates as a survey-row failure rather than a
-- silent zero entry.
templateScheduleStats
  :: TemplateGraph -> Either String TemplateScheduleStats
templateScheduleStats tg = do
  perTpl <- traverse (regionScheduleStats . tplGraph) (tgTemplates tg)
  let agg       = foldr addScheduleStats emptyScheduleStats perTpl
      layers    = templateLayers tg
      widths    = map length layers
      hazards   = map templateLayerSharedWriteHazards layers
      runnableW =
        [ length layer
        | (layer, hz) <- zip layers hazards
        , hz == 0
        ]
      reductionW =
        [ length layer
        | (layer, hz) <- zip layers hazards
        , hz > 0
        ]
  pure TemplateScheduleStats
    { tssTemplateCount              = length (tgTemplates tg)
    , tssMaxTemplateLayerWidth      = maxOr0 widths
    , tssSharedWriteHazards         = sum hazards
    , tssMaxTemplateRunnableWidth   = maxOr0 runnableW
    , tssMaxTemplateReductionWidth  = maxOr0 reductionW
    , tssAggregate                  = agg
    }

-- | Kahn's by-layer over 'tgPrecedence': the width of each
-- precedence-DAG layer is the count of templates whose predecessors
-- are all already scheduled.
--
-- @tgPrecedence@ is keyed by the /reader/ template (the one that
-- depends), so a template missing from the map has no predecessors
-- and lands in layer 0.
templateLayers :: TemplateGraph -> [[Template]]
templateLayers tg =
  let tids       = map tplID (tgTemplates tg)
      byId       = M.fromList [(tplID t, t) | t <- tgTemplates tg]
      precedence = tgPrecedence tg
      depsOf t   = M.findWithDefault S.empty t precedence
      goLayers _ [] = []
      goLayers done remaining =
        let ready t = S.null (depsOf t `S.difference` done)
            (layer, rest) = partition ready remaining
        in if null layer
             then [remaining]   -- defensive: cycle was already
                                -- rejected upstream
             else layer
                  : goLayers (foldr S.insert done layer) rest
  in map (map (byId M.!)) (goLayers S.empty tids)

templateLayerSharedWriteHazards :: [Template] -> Int
templateLayerSharedWriteHazards layer =
  length
    [ bus
    | bus <- S.toList allWrites
    , let writers =
            [ tplID t
            | t <- layer
            , bus `S.member` bfWrites (rfBuses (tplFootprint t))
            ]
    , length writers > 1
    ]
  where
    allWrites = S.unions [bfWrites (rfBuses (tplFootprint t)) | t <- layer]

maxOr0 :: [Int] -> Int
maxOr0 [] = 0
maxOr0 xs = maximum xs
