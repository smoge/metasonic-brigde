{-# LANGUAGE LambdaCase #-}

-- | QuickCheck properties for the core compiler pipeline: dense
-- 'NodeIndex' allocation, topo-order invariants on 'rnInputs',
-- count-preservation through 'lowerGraph', the kindSpec ↔ ugenView
-- arity contract, region-formation invariants (partition, node-map
-- agreement, deps well-formedness, rate compatibility), the
-- 'RuntimeGraph' region overlay round-trip and contiguity contract,
-- the 'rnOutputUse' / 'rnConsumerCount' classifiers, same-bus
-- writer-before-reader ordering, and the rate-propagation lattice
-- laws (floor lower bound, input lower bound, idempotence,
-- structural preservation).
--
-- Every property uses 'genWellFormedGraph' and 'shrinkSynthGraph'
-- from "MetaSonic.Spec.CoreShared".
module MetaSonic.Spec.Core.Properties
  ( properties
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (nub, sort, sortBy)
import           Data.Maybe                (mapMaybe)
import           Data.Ord                  (comparing)

import           Test.Tasty
import           Test.Tasty.QuickCheck     as QC

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

import           MetaSonic.Spec.CoreShared

properties :: TestTree
properties = testGroup "Properties"
  [ QC.testProperty "compileRuntimeGraph: indices are [0..n-1]" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDenseIndices

  , QC.testProperty "compileRuntimeGraph: every RFrom is in [0, n) and earlier" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propTopoOrder

  , QC.testProperty "lowerGraph preserves node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPreservesCount

  , QC.testProperty "validateAndSort succeeds on well-formed graphs" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propValidates

  , QC.testProperty "ugenView arities match kindSpec for every UGen" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propUgenViewMatchesSpec

  , QC.testProperty "compileRuntimeGraph is deterministic" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDeterministic

  , QC.testProperty "every source NodeID appears once as rnOriginalID" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBijection

  , QC.testProperty "kind multiset preserved from source to runtime" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propKindCounts

  , QC.testProperty "Out-spec count preserved as KOut node count" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutCount

  , QC.testProperty "dependencies of every UGen point at existing nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propDepsExist

  , QC.testProperty "regions partition the IR nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionPartition

  , QC.testProperty "rgNodeMap and regNodes agree" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionNodeMapConsistent

  , QC.testProperty "region IDs are unique" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionIDsUnique

  , QC.testProperty "region deps refer only to existing regions, no self-edges" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionDepsWellFormed

  , QC.testProperty "every region's rate is compatible with its member nodes" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRegionRateCompatible

  , QC.testProperty "RuntimeGraph region overlay round-trips formRegions" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsRoundTrip

  , QC.testProperty "RuntimeGraph regions partition node indices contiguously" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRuntimeRegionsContiguous

  , QC.testProperty "rnOutputUse classification matches consumer-region membership" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propOutputUseConsistent

  , QC.testProperty "rnConsumerCount matches direct FromNode references" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propConsumerCountConsistent

  , QC.testProperty "every BusOut precedes every same-bus BusIn in the schedule" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propBusOrdering

  , -- Rate propagation: see Note [Rate inference vs rate propagation]
    -- in "MetaSonic.Bridge.IR" for the algorithm. These properties pin
    -- the three structural invariants of the lift:
    --
    --   1. each node's rate is at least its kind's floor
    --   2. each node's rate is at least every input's rate
    --   3. running the lift twice is the same as running it once
    --
    -- (1) is the kind-floor guarantee. (2) is the join law of the
    -- lattice — the whole point of propagation. (3) is idempotence:
    -- the lift reaches a fixed point in one pass.
    QC.testProperty "every node's irRate ≥ kind floor (post-propagation)" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastFloor

  , QC.testProperty "every node's irRate ≥ max of its inputs' rates" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propRateAtLeastInputs

  , QC.testProperty "propagateRates is idempotent on lowered IR" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationIdempotent

  , QC.testProperty "propagateRates preserves all fields except irRate" $
      forAllShrink genWellFormedGraph shrinkSynthGraph propPropagationStructural
  ]

propDenseIndices :: SynthGraph -> Property
propDenseIndices g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n   = length (rgNodes rt)
        idx = [ i | RuntimeNode { rnIndex = NodeIndex i } <- rgNodes rt ]
    in idx === [0 .. n - 1]

propTopoOrder :: SynthGraph -> Property
propTopoOrder g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let n = length (rgNodes rt)
    in conjoin
         [ counterexample ("node " <> show (rnIndex node)) $
             all (refsEarlier n (rnIndex node)) (rnInputs node)
         | node <- rgNodes rt
         ]
  where
    refsEarlier n (NodeIndex dst) (RFrom (NodeIndex src) _) =
      src >= 0 && src < dst && src < n
    refsEarlier _ _               (RConst _)                = True

propPreservesCount :: SynthGraph -> Property
propPreservesCount g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> length (giNodes ir) === M.size (sgNodes g)

propValidates :: SynthGraph -> Property
propValidates g = case validateAndSort g of
  Left err -> counterexample ("validateAndSort failed: " <> err) False
  Right _  -> property True

-- | Drift guard for the per-kind metadata: for every UGen in a
-- generated graph, the arities reported by @ugenView@ must match
-- the @kindSpec@ table.
propUgenViewMatchesSpec :: SynthGraph -> Property
propUgenViewMatchesSpec g = conjoin
  [ counterexample (show u) $
         length (uvInputs   v) === ksAudioArity   ks
    .&&. length (uvControls v) === ksControlArity ks
  | ns <- M.elems (sgNodes g)
  , let u  = nsUgen ns
        v  = ugenView u
        ks = kindSpec (uvKind v)
  ]

-- | Compiling the same graph twice must produce identical RuntimeGraphs.
propDeterministic :: SynthGraph -> Property
propDeterministic g =
  let r1 = lowerGraph g >>= compileRuntimeGraph
      r2 = lowerGraph g >>= compileRuntimeGraph
  in r1 === r2

-- | Every source NodeID appears exactly once as rnOriginalID.
propBijection :: SynthGraph -> Property
propBijection g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    sort (map rnOriginalID (rgNodes rt)) === sort (M.keys (sgNodes g))

-- | The multiset of NodeKinds is preserved from source to runtime.
propKindCounts :: SynthGraph -> Property
propKindCounts g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let byTag    = sortBy (comparing kindTag)
        srcKinds = byTag (map (ugenKind . nsUgen) (M.elems (sgNodes g)))
        rtKinds  = byTag (map rnKind (rgNodes rt))
    in srcKinds === rtKinds

-- | Number of Out specs in the source equals number of KOut nodes in
-- the runtime.
propOutCount :: SynthGraph -> Property
propOutCount g = case lowerGraph g >>= compileRuntimeGraph of
  Left err -> counterexample ("compile failed: " <> err) False
  Right rt ->
    let srcOuts = length [ () | NodeSpec { nsUgen = Out{} } <- M.elems (sgNodes g) ]
        rtOuts  = length [ () | n <- rgNodes rt, rnKind n == KOut ]
    in srcOuts === rtOuts

-- | Every NodeID returned by 'dependencies' on a node in the graph
-- must be a node-key in that graph.
propDepsExist :: SynthGraph -> Property
propDepsExist g =
  let nodes = sgNodes g
      keys  = M.keysSet nodes
      bad   = [ (nid, dep)
              | (nid, spec) <- M.toList nodes
              , dep <- dependencies (nsUgen spec)
              , dep `S.notMember` keys
              ]
  in counterexample ("dangling deps: " <> show bad) (null bad)

------------------------------------------------------------
-- Region-formation invariants
------------------------------------------------------------

-- | Every IR node appears in exactly one region.
propRegionPartition :: SynthGraph -> Property
propRegionPartition g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg          = formRegions (giNodes ir)
        regionIDs   = concatMap regNodes (rgRegions rg)
        irNodeIDs   = map irNodeID (giNodes ir)
    in conjoin
         [ counterexample "region members are not unique" $
             length regionIDs === length (nub regionIDs)
         , counterexample "region members ≠ IR nodes" $
             sort regionIDs === sort irNodeIDs
         ]

-- | rgNodeMap matches regNodes membership both ways.
propRegionNodeMapConsistent :: SynthGraph -> Property
propRegionNodeMapConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg = formRegions (giNodes ir)
        forwardOK =
          [ M.lookup nid (rgNodeMap rg) == Just (regID r)
          | r <- rgRegions rg, nid <- regNodes r
          ]
        reverseOK =
          [ nid `elem` regNodes r
          | (nid, rid) <- M.toList (rgNodeMap rg)
          , Just r <- [findRegion rid (rgRegions rg)]
          ]
    in conjoin
         [ counterexample "regNodes → rgNodeMap mismatch" $
             property (and forwardOK)
         , counterexample "rgNodeMap → regNodes mismatch" $
             property (and reverseOK)
         ]
  where
    findRegion rid = lookup rid . map (\r -> (regID r, r))

-- | Region IDs are unique within a RegionGraph.
propRegionIDsUnique :: SynthGraph -> Property
propRegionIDsUnique g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rids = map regID (rgRegions (formRegions (giNodes ir)))
    in length rids === length (nub rids)

-- | Region deps refer only to existing region IDs, and never to a
-- region's own ID.
propRegionDepsWellFormed :: SynthGraph -> Property
propRegionDepsWellFormed g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        allIDs = S.fromList (map regID (rgRegions rg))
    in conjoin
         [ counterexample (show (regID r) <> " has bad deps: " <> show (regDeps r)) $
             property $
               regDeps r `S.isSubsetOf` allIDs
               && regID r `S.notMember` regDeps r
         | r <- rgRegions rg
         ]

-- | Every same-bus (BusWrite n, BusRead n) pair must have the writer
-- precede the reader in the topological order. This is the property
-- version of the unit tests in @Bus routing (BusIn/BusOut and E_r
-- edges)@: it asserts that 'effectiveDeps' actually puts every
-- writer before every reader, on every randomly generated graph.
--
-- Cycles in E_s ∪ E_r show up as a 'Left' from 'validateAndSort' and
-- are skipped (the cycle-rejection unit test covers those).
propBusOrdering :: SynthGraph -> Property
propBusOrdering g = case validateAndSort g of
  Left _    -> property True
  Right ord ->
    let posOf   = M.fromList (zip ord [(0 :: Int) ..])
        nodes   = M.toList (sgNodes g)
        writers = [ (nid, n) | (nid, ns) <- nodes
                             , BusWrite n <- inferEff (nsUgen ns) ]
        readers = [ (nid, n) | (nid, ns) <- nodes
                             , BusRead  n <- inferEff (nsUgen ns) ]
        bad =
          [ (w, r, n)
          | (w, bw) <- writers
          , (r, br) <- readers
          , bw == br
          , let n  = bw
                pw = posOf M.! w
                pr = posOf M.! r
          , pw >= pr
          ]
    in counterexample ("bad bus orderings: " <> show bad) (null bad)

-- | Every node's propagated rate must be at least its kind's floor.
-- This is the trivial half of the join: a kind floor is one of the
-- arguments of 'max', so the result is always ≥ the floor.
propRateAtLeastFloor :: SynthGraph -> Property
propRateAtLeastFloor g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> conjoin
    [ counterexample
        ("node " <> show (irNodeID n) <> " of kind " <> show (irKind n)
          <> ": irRate " <> show (irRate n)
          <> " < floor " <> show floor_)
        (irRate n >= floor_)
    | n <- giNodes ir
    , let floor_ = ksRate (kindSpec (irKind n))
    ]

-- | Every node's propagated rate must be at least the maximum rate of
-- its inputs (FromNode inputs contribute the source node's rate;
-- Literal inputs contribute CompileRate). This is the load-bearing
-- half of the join: it's the property that makes
-- 'MetaSonic.Bridge.IR.checkRateEdges' vacuous post-propagation.
propRateAtLeastInputs :: SynthGraph -> Property
propRateAtLeastInputs g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rateMap = M.fromList [ (irNodeID n, irRate n) | n <- giNodes ir ]
    in conjoin
         [ counterexample
             ("node " <> show (irNodeID n)
               <> ": irRate " <> show (irRate n)
               <> " < input rate " <> show inRate
               <> " (input " <> show inp <> ")")
             (irRate n >= inRate)
         | n   <- giNodes ir
         , inp <- irInputs n
         , let inRate = case inp of
                 FromNode src _ -> M.findWithDefault CompileRate src rateMap
                 Literal _      -> CompileRate
         ]

-- | Propagation reaches a fixed point in one pass. Running it twice
-- on a lowered IR must yield the same IR as running it once. This is
-- a defensive correctness check: a non-idempotent join would mean
-- some node's rate is changing on the second pass, which can only
-- happen if the first pass missed a join somewhere.
propPropagationIdempotent :: SynthGraph -> Property
propPropagationIdempotent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> propagateRates ir === ir

-- | Propagation only touches 'irRate'. NodeID, kind, inputs,
-- controls, and effects must be byte-identical before and after.
-- A regression here would mean the lift is mutating something it
-- shouldn't — and any of those fields drifting would break
-- downstream lowering, FFI marshalling, or scheduling.
propPropagationStructural :: SynthGraph -> Property
propPropagationStructural g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let lifted = propagateRates ir
        same field name =
          counterexample ("propagation changed " <> name) $
            map field (giNodes ir) === map field (giNodes lifted)
    in conjoin
         [ same irNodeID   "irNodeID"
         , same irKind     "irKind"
         , same irInputs   "irInputs"
         , same irControls "irControls"
         , same irEffects  "irEffects"
         ]

-- | Region rate is consistent with its members'. After CompileRate
-- absorption (see Note [Region rate compatibility] in
-- MetaSonic.Bridge.Compile), member rates may differ from 'regRate':
-- a CompileRate helper folded into a SampleRate region keeps its own
-- 'irRate = CompileRate' while the region's 'regRate' stays SampleRate.
-- Two invariants together replace the old "all equal" check:
--
--   1. Every member rate is compatible with 'regRate', i.e. either
--      equal to it or 'CompileRate'.
--   2. 'regRate' is the maximum of member rates, so at least one
--      member's rate equals 'regRate' (the dominant one that drove
--      the join).
propRegionRateCompatible :: SynthGraph -> Property
propRegionRateCompatible g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir ->
    let rg     = formRegions (giNodes ir)
        nodes  = giNodes ir
        rateOf nid = irRate <$> findNode nid nodes
        memberRates r = [ mr | nid <- regNodes r, Just mr <- [rateOf nid] ]
        compatible rr mr = mr == rr || mr == CompileRate
    in conjoin
         [ conjoin
             [ counterexample
                 (show (regID r) <> ": member " <> show nid
                    <> " has rate " <> show (rateOf nid)
                    <> " not compatible with regRate " <> show (regRate r))
                 $ property $ maybe False (compatible (regRate r)) (rateOf nid)
             | nid <- regNodes r
             ] .&&.
             counterexample
               (show (regID r) <> ": regRate " <> show (regRate r)
                  <> " is not max of member rates " <> show (memberRates r))
               (property $ regRate r == maximum (regRate r : memberRates r)
                          && regRate r `elem` memberRates r)
         | r <- rgRegions rg
         ]
  where
    findNode nid = lookup nid . map (\n -> (irNodeID n, n))

-- | Step A round-trip property: the runtime region overlay produced
-- by 'compileRuntimeGraph' starts from 'formRegions (giNodes ir)'
-- and may then be split by 'selectRegionKernels'. The final runtime
-- regions must therefore be a rate-preserving refinement of the raw
-- formRegions output, with the same per-region NodeID-to-NodeIndex
-- membership when adjacent refined regions are concatenated.
propRuntimeRegionsRoundTrip :: SynthGraph -> Property
propRuntimeRegionsRoundTrip g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let compileRegions = rgRegions (formRegions (giNodes ir))
          runtime        = rgRuntimeRegions rg
          indexMap = M.fromList
            [ (rnOriginalID n, rnIndex n) | n <- rgNodes rg ]
          translate nid = M.lookup nid indexMap
          expected =
            [ (regRate cr, mapMaybe translate (regNodes cr))
            | cr <- compileRegions
            ]
      in case checkRuntimeRegionRefinement expected runtime of
           Right () -> property True
           Left msg -> counterexample msg False

checkRuntimeRegionRefinement
  :: [(Rate, [NodeIndex])]
  -> [RuntimeRegion]
  -> Either String ()
checkRuntimeRegionRefinement [] [] = Right ()
checkRuntimeRegionRefinement [] extra =
  Left $ "unexpected extra runtime regions: " <> show (map rrIndex extra)
checkRuntimeRegionRefinement ((rate, expectedNodes) : rest) runtime =
  let (chunk, remaining) = takeRuntimeChunk (length expectedNodes) runtime
      actualNodes = concatMap rrNodes chunk
      rates = map rrRate chunk
  in if null chunk
       then Left $ "missing runtime regions for expected nodes " <> show expectedNodes
       else if actualNodes /= expectedNodes
         then Left $
           "runtime region refinement changed members: expected "
           <> show expectedNodes <> ", got " <> show actualNodes
         else if any (/= rate) rates
           then Left $
             "runtime region refinement changed rate for "
             <> show expectedNodes <> ": expected " <> show rate
             <> ", got " <> show rates
           else checkRuntimeRegionRefinement rest remaining

takeRuntimeChunk
  :: Int
  -> [RuntimeRegion]
  -> ([RuntimeRegion], [RuntimeRegion])
takeRuntimeChunk targetLen = go [] 0
  where
    go acc _ [] = (reverse acc, [])
    go acc len rest@(r : rs)
      | len >= targetLen = (reverse acc, rest)
      | otherwise =
          go (r : acc) (len + length (rrNodes r)) rs

-- | Step A structural invariant: every 'RuntimeRegion' covers a
-- contiguous run of 'NodeIndex' values, regions concatenate in order
-- to exactly @[0 .. length (rgNodes rg) - 1]@, and no node is in
-- two regions. This locks the contiguity contract the C++ side
-- relies on (RegionSpec carries first_node + node_count).
propRuntimeRegionsContiguous :: SynthGraph -> Property
propRuntimeRegionsContiguous g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let runtime    = rgRuntimeRegions rg
          unwrap (NodeIndex i) = i
          flat       = concatMap (map unwrap . rrNodes) runtime
          totalNodes = length (rgNodes rg)
          eachContiguous =
            [ counterexample (show (rrIndex r) <> ": members are not contiguous: " <> show ixs) $
                property $
                  let ixs = map unwrap (rrNodes r)
                  in not (null ixs)
                       && ixs == [head ixs .. head ixs + length ixs - 1]
            | r <- runtime
            , let ixs = map unwrap (rrNodes r)
            ]
      in conjoin
           [ counterexample "regions do not concatenate to [0 .. n-1]" $
               flat === [0 .. totalNodes - 1]
           , conjoin eachContiguous
           ]

-- | Step B-Light: 'rnOutputUse' must agree with the actual consumer /
-- region structure. Three invariants:
--
--   1. 'NoOutput' iff the node's kind is a sink ('KOut' / 'KBusOut').
--   2. 'RegionLocal' iff the node has output AND every consumer is in
--      the same region (vacuously true when there are no consumers).
--   3. 'RegionEscapes' iff the node has output AND at least one
--      consumer is in a different region.
--
-- See Note [Output-use classification] in MetaSonic.Bridge.Compile.
propOutputUseConsistent :: SynthGraph -> Property
propOutputUseConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let nodeRegion = M.fromList
            [ (ix, rrIndex r)
            | r <- rgRuntimeRegions rg, ix <- rrNodes r
            ]
          consumersOf ix =
            [ rnIndex c
            | c <- rgNodes rg
            , RFrom src _ <- rnInputs c
            , src == ix
            ]
          isSink k = k == KOut || k == KBusOut
          expected n
            | isSink (rnKind n) = NoOutput
            | otherwise =
                let myReg = M.lookup (rnIndex n) nodeRegion
                    cs    = consumersOf (rnIndex n)
                    same  = all (\c -> M.lookup c nodeRegion == myReg) cs
                in if same then RegionLocal else RegionEscapes
      in conjoin
           [ counterexample
               (show (rnIndex n) <> " (" <> show (rnKind n)
                  <> "): rnOutputUse = " <> show (rnOutputUse n)
                  <> ", expected " <> show (expected n))
               (rnOutputUse n === expected n)
           | n <- rgNodes rg
           ]

-- | 'rnConsumerCount' equals the number of direct 'FromNode'
-- references to this node across 'rgNodes'. The crisp Step-C
-- single-edge fusion predicate (rnOutputUse == RegionLocal &&
-- rnConsumerCount == 1) only works if this count is honest.
propConsumerCountConsistent :: SynthGraph -> Property
propConsumerCountConsistent g = case lowerGraph g of
  Left err -> counterexample ("lowerGraph failed: " <> err) False
  Right ir -> case compileRuntimeGraph ir of
    Left err -> counterexample ("compileRuntimeGraph failed: " <> err) False
    Right rg ->
      let countFor ix =
            length
              [ ()
              | c <- rgNodes rg
              , RFrom src _ <- rnInputs c
              , src == ix
              ]
      in conjoin
           [ counterexample
               (show (rnIndex n) <> ": rnConsumerCount = "
                  <> show (rnConsumerCount n)
                  <> ", direct count = " <> show (countFor (rnIndex n)))
               (rnConsumerCount n === countFor (rnIndex n))
           | n <- rgNodes rg
           ]
