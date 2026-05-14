-- |
-- Module      : MetaSonic.Authoring.Report
-- Description : Phase 8.G — app-level authoring metadata reporting
--
-- An app-level projection of the authoring metadata that
-- 'MetaSonic.Authoring' records: ensemble templates + roles,
-- named buses, and named controls. The projections live
-- alongside the authoring layer (in the library) so reporting
-- callers can construct + render them and tests can pin the
-- text.
--
-- These types are not embedded in 'SynthGraph' or
-- 'TemplateGraph'; the compiler does not see them. They are
-- read-only metadata for diagnostic surfaces:
-- @--inspect-only@ and @--fusion-survey@. Adding a new field
-- here does not affect compile output.
--
-- See [notes/2026-05-12-l-phase-8g-metadata-reporting.md].

module MetaSonic.Authoring.Report
  ( -- * Authoring report carrier
    AuthoringReport (..)
  , ReportedTemplate (..)
  , ReportedBus (..)
  , ReportedControl (..)

    -- * Construction
  , emptyAuthoringReport
  , ensembleReport
  , addReportedControl

    -- * Rendering
  , renderAuthoringReport
  ) where

import           Data.List         (sortBy)
import qualified Data.Map.Strict   as M
import           Data.Word         (Word8)

import qualified MetaSonic.Authoring as Auth
import           MetaSonic.Bridge.Source (MigrationKey (..))


-- | One template entry: the declared template name and its
-- diagnostic role tag.
data ReportedTemplate = ReportedTemplate
  { rtName :: !String
  , rtRole :: !Auth.TemplateRole
  } deriving (Eq, Show)

-- | One named bus entry: the authoring-level bus name and
-- the bus index the ensemble allocated for it.
data ReportedBus = ReportedBus
  { rbName  :: !String
  , rbIndex :: !Int
  } deriving (Eq, Show)

-- | One named control entry: every field 'NamedControlMetadata'
-- records, lifted to a plain record so the reporting layer
-- can render without depending on the live 'NamedControl'.
data ReportedControl = ReportedControl
  { rcName        :: !String
  , rcDefault     :: !Double
  , rcRange       :: !(Double, Double)
  , rcSmoothingHz :: !Double
  , rcCC          :: !(Maybe Word8)
  , rcKey         :: !MigrationKey
  , rcSlot        :: !Int
  } deriving (Eq, Show)

-- | The full authoring report for one demo.
data AuthoringReport = AuthoringReport
  { arTemplates :: ![ReportedTemplate]
  , arBuses     :: ![ReportedBus]
  , arControls  :: ![ReportedControl]
  } deriving (Eq, Show)

-- | An empty report. Useful as a base value when a demo only
-- adds named controls without using the ensemble builder.
emptyAuthoringReport :: AuthoringReport
emptyAuthoringReport = AuthoringReport
  { arTemplates = []
  , arBuses     = []
  , arControls  = []
  }

-- | Project an 'AuthoredEnsemble' into a report. Templates
-- come from 'amRoles' in declaration order; buses come from
-- 'amBuses' sorted by allocated index so the rendering order
-- is stable across 'Map' iterations.
ensembleReport :: Auth.AuthoredEnsemble -> AuthoringReport
ensembleReport ae = AuthoringReport
  { arTemplates =
      [ ReportedTemplate { rtName = n, rtRole = r }
      | (n, r) <- Auth.amRoles meta
      ]
  , arBuses =
      [ ReportedBus
          { rbName  = name
          , rbIndex = Auth.unBus b
          }
      | (name, b) <- sortBy cmpBus (M.toList (Auth.amBuses meta))
      ]
  , arControls = []
  }
  where
    meta = Auth.aeMetadata ae
    cmpBus (_, b1) (_, b2) =
      compare (Auth.unBus b1) (Auth.unBus b2)

-- | Append one 'NamedControl' to a report. Demos call this
-- for each control returned by their 'runSynthWith' /
-- 'runSynthCCs' body.
addReportedControl
  :: Auth.NamedControl
  -> AuthoringReport
  -> AuthoringReport
addReportedControl nc r = r
  { arControls = arControls r <> [view] }
  where
    md   = Auth.ncMetadata nc
    view = ReportedControl
      { rcName        = Auth.ncmName md
      , rcDefault     = Auth.ncmDefault md
      , rcRange       =
          ( Auth.crMin (Auth.ncmRange md)
          , Auth.crMax (Auth.ncmRange md)
          )
      , rcSmoothingHz = Auth.ncmSmoothingHz md
      , rcCC          = Auth.ncmCC md
      , rcKey         = Auth.ncmKey md
      , rcSlot        = Auth.ncmSlot md
      }

-- | Render an authoring report as a list of lines. Empty
-- input or an empty report (no templates, no buses, no
-- controls) produces no output, so callers do not need a
-- separate "is anything to print" check.
--
-- Ordering is the order recorded in the report record.
-- Tests can pin the line list verbatim.
renderAuthoringReport :: Maybe AuthoringReport -> [String]
renderAuthoringReport Nothing  = []
renderAuthoringReport (Just r)
  | null (arTemplates r)
    && null (arBuses r)
    && null (arControls r) = []
  | otherwise = concat
      [ ["", "  ─── Authoring metadata ───"]
      , renderTemplates (arTemplates r)
      , renderBuses     (arBuses r)
      , renderControls  (arControls r)
      ]
  where
    renderTemplates [] = []
    renderTemplates ts =
      "  Templates:"
      : [ "    " <> rtName t
          <> "  (" <> roleLabel (rtRole t) <> ")"
        | t <- ts ]

    renderBuses [] = []
    renderBuses bs =
      "  Named buses:"
      : [ "    " <> rbName b <> " → " <> show (rbIndex b)
        | b <- bs ]

    renderControls [] = []
    renderControls cs =
      "  Named controls:"
      : map renderControl cs

    renderControl c =
      let (mn, mx) = rcRange c
          ccPart   = case rcCC c of
            Nothing -> ""
            Just n  -> "  cc=" <> show n
      in "    " <> rcName c
         <> "  default=" <> show (rcDefault c)
         <> "  range=[" <> show mn <> ", " <> show mx <> "]"
         <> "  smooth=" <> show (rcSmoothingHz c)
         <> ccPart
         <> "  key=" <> unMigrationKey (rcKey c)
         <> "  slot=" <> show (rcSlot c)

    roleLabel Auth.VoiceTemplate = "voice template"
    roleLabel Auth.FxTemplate    = "fx template"
