{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : MetaSonic.Visualize.Trace
-- Description : Capture intermediate results
--
-- traceCompile runs the pipeline as far as it can and records
-- each intermediate representation. The result is a pure snapshot;
-- the Brick TUI never calls compiler passes itself.

module MetaSonic.Visualize.Trace
  ( TraceStage (..)
  , CompileTrace (..)
  , traceCompile
  , traceReached
  , traceStageError
  , traceSourceNodes
  ) where

import qualified Data.Map.Strict           as M
import           Data.Maybe                (fromMaybe)

import           MetaSonic.Bridge.Compile  (RegionGraph, RuntimeGraph,
                                            compileRuntimeGraph, formRegions)
import           MetaSonic.Bridge.IR       (GraphIR (..), lowerGraph)
import           MetaSonic.Bridge.Source   (NodeSpec, SynthGraph (..))
import           MetaSonic.Bridge.Validate (validateAndSort)
import           MetaSonic.Types           (NodeID)

-- | Stages as seen by the visualizer
data TraceStage
  = TraceSource
  | TraceOrder
  | TraceIR
  | TraceRegions
  | TraceRuntime
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Snapshot of every stage.
--
-- Stages that were not reached are 'Nothing'. When a failure occurs,
-- 'ctFailedAt' names the stage that failed and 'ctError' carries the
-- diagnostic.
data CompileTrace = CompileTrace
  { ctSource       :: !SynthGraph
  , ctExecOrder    :: !(Maybe [NodeID])
  , ctSourceByExec :: !(Maybe [NodeSpec])
    -- ^ Source nodes projected into execution order, so the Source tab
    -- can line up with later stages.
  , ctIR           :: !(Maybe GraphIR)
  , ctRegions      :: !(Maybe RegionGraph)
  , ctRuntime      :: !(Maybe RuntimeGraph)
  , ctFailedAt     :: !(Maybe TraceStage)
  , ctError        :: !(Maybe String)
  }
  deriving (Eq, Show)

-- | Run the pipeline, recording intermediate results.
--
-- It intentionally calls 'validateAndSort' separately before 'lowerGraph':
-- the trace wants to preserve the execution order even when lowering later
-- fails (for example during semantic checks). That duplicates the sort, but
-- keeps the diagnostic snapshot honest.
traceCompile :: SynthGraph -> CompileTrace
traceCompile sg =
  let !base = CompileTrace
        { ctSource       = sg
        , ctExecOrder    = Nothing
        , ctSourceByExec = Nothing
        , ctIR           = Nothing
        , ctRegions      = Nothing
        , ctRuntime      = Nothing
        , ctFailedAt     = Nothing
        , ctError        = Nothing
        }

      !sourceMap = sgNodes sg

      lookupSource :: NodeID -> NodeSpec
      lookupSource nid =
        fromMaybe
          (error ("traceCompile: missing NodeSpec for " <> show nid))
          (M.lookup nid sourceMap)

  in
    case validateAndSort sg of
      Left err ->
        base
          { ctFailedAt = Just TraceOrder
          , ctError    = Just err
          }

      Right execOrder ->
        let !t1 = base
              { ctExecOrder    = Just execOrder
              , ctSourceByExec = Just (map lookupSource execOrder)
              }
        in
          case lowerGraph sg of
            Left err ->
              t1
                { ctFailedAt = Just TraceIR
                , ctError    = Just err
                }

            Right ir ->
              let !regions = formRegions (giNodes ir)
                  !t2 = t1
                    { ctIR      = Just ir
                    , ctRegions = Just regions
                    }
              in
                case compileRuntimeGraph ir of
                  Left err ->
                    t2
                      { ctFailedAt = Just TraceRuntime
                      , ctError    = Just err
                      }

                  Right rt ->
                    t2 { ctRuntime = Just rt }

-- | Whether the trace successfully reached a stage.
traceReached :: CompileTrace -> TraceStage -> Bool
traceReached _  TraceSource  = True
traceReached ct TraceOrder   = maybe False (const True) (ctExecOrder ct)
traceReached ct TraceIR      = maybe False (const True) (ctIR ct)
traceReached ct TraceRegions = maybe False (const True) (ctRegions ct)
traceReached ct TraceRuntime = maybe False (const True) (ctRuntime ct)

-- | The error for one stage, if that stage is where the compilation/pipeline failed.
traceStageError :: CompileTrace -> TraceStage -> Maybe String
traceStageError ct stage
  | ctFailedAt ct == Just stage = ctError ct
  | otherwise                   = Nothing

-- | Source nodes for display.
--
-- When ordering succeeded it returns source nodes in execution order so that
-- the Source tab aligns with next tabs. Otherwise we fall back to the raw
-- map order, so the UI still has something to show.
traceSourceNodes :: CompileTrace -> [NodeSpec]
traceSourceNodes ct =
  fromMaybe (M.elems (sgNodes (ctSource ct))) (ctSourceByExec ct)
