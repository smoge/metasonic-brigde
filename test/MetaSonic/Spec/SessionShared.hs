-- | Shared helpers for session-oriented spec modules.
module MetaSonic.Spec.SessionShared
  ( testProducer
  , totalTemplateNodes
  , withInstalledAdapter
  , duplicateFirstTwoTemplates
  , compileTemplateGraphOrFail
  ) where

import qualified Data.Text                       as T
import           Foreign.Ptr                     (Ptr)

import           Test.Tasty.HUnit                (assertFailure)

import           MetaSonic.Bridge.Compile        (rgNodes)
import           MetaSonic.Bridge.FFI            (RTGraph, withRTGraph)
import           MetaSonic.Bridge.Source         (SynthGraph)
import           MetaSonic.Bridge.Templates      (TemplateGraph (..),
                                                  compileTemplateGraph,
                                                  tgTemplates, tplGraph,
                                                  tplName)
import           MetaSonic.Session.Queue         (ProducerId (..), ProducerKind)
import           MetaSonic.Session.RTGraphAdapter (RTGraphAdapterOptions,
                                                   newRTGraphAdapter)
import           MetaSonic.Session.Runtime       (SessionRuntimeAdapter)


testProducer :: ProducerKind -> String -> ProducerId
testProducer kind name =
  ProducerId kind (T.pack name)

-- | Total node count across every template in a 'TemplateGraph'.
-- Used to size the RTGraph capacity (plus a small slack) when
-- installing a graph end-to-end through 'newRTGraphAdapter'.
totalTemplateNodes :: TemplateGraph -> Int
totalTemplateNodes tg =
  sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

-- | Provision an RTGraph capacity that fits @tg@ plus 16 slack
-- slots, install the graph through 'newRTGraphAdapter', and run
-- @action@ against the resulting handle pair. Adapter setup
-- failure aborts the test loudly via 'assertFailure'.
withInstalledAdapter
  :: TemplateGraph
  -> RTGraphAdapterOptions
  -> (Ptr RTGraph -> SessionRuntimeAdapter IO -> IO a)
  -> IO a
withInstalledAdapter tg opts action =
  withRTGraph (totalTemplateNodes tg + 16) 64 $ \rt -> do
    result <- newRTGraphAdapter rt tg opts
    case result of
      Left issue ->
        assertFailure ("expected RTGraph adapter, got: " <> show issue)
      Right adapter ->
        action rt adapter

-- | Force a 'TemplateGraph' to advertise the same name on its
-- first two templates. Used by duplicate-template-name regression
-- tests across multiple session cohorts (Prep E install, Prep F
-- owner, Prep G queue / arbitration).
duplicateFirstTwoTemplates :: TemplateGraph -> TemplateGraph
duplicateFirstTwoTemplates base =
  case tgTemplates base of
    (a : b : rest) ->
      base { tgTemplates =
               a { tplName = "dup" }
             : b { tplName = "dup" }
             : rest
           }
    _ ->
      error "expected at least two templates for duplicate-name test"

-- | Compile a list of @(name, SynthGraph)@ pairs into a
-- 'TemplateGraph', aborting the test loudly via 'assertFailure'
-- if 'compileTemplateGraph' rejects the input. Used by hot-swap
-- and preserving-migration cases that need a freshly-compiled
-- target graph (e.g. the 'hotSwapEditAfterTemplates' corpus).
compileTemplateGraphOrFail :: [(String, SynthGraph)] -> IO TemplateGraph
compileTemplateGraphOrFail entries =
  case compileTemplateGraph entries of
    Left err ->
      assertFailure ("expected TemplateGraph, got: " <> err)
    Right tg ->
      pure tg
