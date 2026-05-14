{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : MetaSonic.Session.ManifestReload
-- Description : Pure planning for manifest-driven session reloads.
--
-- This module validates an authoring manifest against a caller-supplied
-- graph catalog and derives static session resource policy. It does not
-- reconstruct graphs from JSON, allocate an RTGraph, step a session owner,
-- or choose a live hot-swap protocol.
--
-- See [notes/2026-05-14-manifest-session-reload-policy.md].

module MetaSonic.Session.ManifestReload
  ( -- * Catalog
    ManifestReloadCatalogEntry (..)

    -- * Request
  , ManifestReloadRequest (..)
  , ManifestResourcePolicy (..)
  , defaultManifestResourcePolicy
  , ManifestControlSurface (..)

    -- * Plan
  , ManifestReloadPlan (..)

    -- * Issues
  , ManifestReloadIssue (..)
  , ManifestResourcePolicyIssue (..)

    -- * Planning
  , planManifestReload

    -- * Runtime projections
  , manifestReloadCommand
  , manifestSessionOwnerOptions
  ) where

import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S
import           Data.Bifunctor                 (first)
import           Data.Foldable                  (traverse_)
import           Data.Word                      (Word8)
import           GHC.Generics                   (Generic)

import           MetaSonic.Authoring.Manifest   (AuthoringManifest (..),
                                                 AuthoringManifestDoc (..),
                                                 ManifestControl (..),
                                                 ManifestTemplate (..),
                                                 manifestSchemaVersion)
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Bridge.Templates     (Template (..),
                                                 TemplateGraph (..))
import           MetaSonic.Pattern              (ControlTag (..), SwapLabel,
                                                 TemplateName (..))
import           MetaSonic.Session.Arbitration  (ArbitrationPolicy (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.Owner        (SessionOwnerOptions (..))
import           MetaSonic.Session.RTGraphAdapter
                                                (RTGraphAdapterOptions (..),
                                                 defaultRTGraphAdapterOptions)


-- | One reloadable catalog entry supplied by the app or product host.
--
-- The manifest is required, not optional: it is the expected authoring
-- surface for the graph this entry can rebuild.
data ManifestReloadCatalogEntry = ManifestReloadCatalogEntry
  { mrcDemoKey       :: !String
  , mrcManifest      :: !AuthoringManifest
  , mrcTemplateGraph :: !TemplateGraph
  } deriving (Eq, Show, Generic)

-- | One pure reload-planning request.
data ManifestReloadRequest = ManifestReloadRequest
  { mrrDemoKey        :: !String
  , mrrSwapLabel      :: !SwapLabel
  , mrrResourcePolicy :: !ManifestResourcePolicy
  } deriving (Eq, Show, Generic)

-- | Static template-polyphony policy for manifest reload planning.
--
-- Runtime timing knobs, including hot-swap install timeout, stay on the
-- downstream runtime/owner configuration path.
data ManifestResourcePolicy = ManifestResourcePolicy
  { mrpVoicePolyphony    :: !Int
  , mrpFxPolyphony       :: !Int
  , mrpTemplateOverrides :: !(M.Map TemplateName Int)
  } deriving (Eq, Show, Generic)

-- | Conservative static resource policy.
--
-- The planner expands this into explicit per-template polyphony entries
-- in 'RTGraphAdapterOptions'. Runtime sizing knobs such as builder capacity,
-- max frames, and hot-swap timeout remain downstream owner configuration.
defaultManifestResourcePolicy :: ManifestResourcePolicy
defaultManifestResourcePolicy = ManifestResourcePolicy
  { mrpVoicePolyphony    = 1
  , mrpFxPolyphony       = 1
  , mrpTemplateOverrides = M.empty
  }

-- | Session-facing projection of one authoring manifest control.
--
-- The projection keeps control metadata useful to UI, OSC, MIDI, or
-- later arbitration code without giving the manifest ownership over
-- any producer target.
data ManifestControlSurface = ManifestControlSurface
  { mcsDisplayName :: !String
  , mcsControlTag  :: !ControlTag
  , mcsDefault     :: !Double
  , mcsRangeMin    :: !Double
  , mcsRangeMax    :: !Double
  , mcsSmoothingHz :: !Double
  , mcsCC          :: !(Maybe Word8)
  } deriving (Eq, Show, Generic)

-- | A validated pure plan that a later runtime integration can turn into
-- owner options plus a hot-swap command.
data ManifestReloadPlan = ManifestReloadPlan
  { mrlpDemoKey           :: !String
  , mrlpSwapLabel         :: !SwapLabel
  , mrlpTemplateGraph     :: !TemplateGraph
  , mrlpAdapterOptions    :: !RTGraphAdapterOptions
  , mrlpControlSurface    :: ![ManifestControlSurface]
  , mrlpArbitrationPolicy :: !ArbitrationPolicy
    -- ^ Default to 'FifoOnly'. A manifest describes controls but does
    -- not claim producer ownership without an explicit policy owner.
  } deriving (Eq, Show, Generic)

data ManifestReloadIssue
  = MriUnsupportedSchemaVersion !Int
  | MriDuplicateManifestDemo !String
  | MriDuplicateCatalogDemo !String
  | MriUnknownManifestDemo !String
  | MriUnknownCatalogDemo !String
  | MriManifestMismatch !String !AuthoringManifest !AuthoringManifest
  | MriDuplicateTemplateName !TemplateName
  | MriCatalogMissingTemplate !TemplateName
  | MriUnknownTemplateRole !String !String
  | MriInvalidResourcePolicy !ManifestResourcePolicyIssue
  deriving (Eq, Show, Generic)

data ManifestResourcePolicyIssue
  = MrpiVoicePolyphonyNonPositive !Int
  | MrpiFxPolyphonyNonPositive !Int
  | MrpiTemplateOverrideNonPositive !TemplateName !Int
  deriving (Eq, Show, Generic)

-- | Validate a decoded authoring manifest document against a caller-owned
-- catalog and produce a static reload plan.
planManifestReload
  :: AuthoringManifestDoc
  -> [ManifestReloadCatalogEntry]
  -> ManifestReloadRequest
  -> Either ManifestReloadIssue ManifestReloadPlan
planManifestReload doc catalog req
  | docSchemaVersion doc /= manifestSchemaVersion =
      Left (MriUnsupportedSchemaVersion (docSchemaVersion doc))
  | Just dup <- firstDuplicate mfDemoKey (docDemos doc) =
      Left (MriDuplicateManifestDemo dup)
  | Just dup <- firstDuplicate mrcDemoKey catalog =
      Left (MriDuplicateCatalogDemo dup)
  | otherwise = do
      requestedManifest <-
        maybe (Left (MriUnknownManifestDemo requestedKey)) Right $
          lookup requestedKey
            [ (mfDemoKey manifest, manifest)
            | manifest <- docDemos doc
            ]
      catalogEntry <-
        maybe (Left (MriUnknownCatalogDemo requestedKey)) Right $
          lookup requestedKey
            [ (mrcDemoKey entry, entry)
            | entry <- catalog
            ]
      validateManifestTemplates requestedManifest
      validateCatalogTemplates requestedManifest (mrcTemplateGraph catalogEntry)
      if requestedManifest /= mrcManifest catalogEntry
         then Left (MriManifestMismatch
                     requestedKey
                     requestedManifest
                     (mrcManifest catalogEntry))
         else do
           adapterOptions <-
             adapterOptionsFor requestedManifest (mrrResourcePolicy req)
           pure ManifestReloadPlan
             { mrlpDemoKey           = requestedKey
             , mrlpSwapLabel         = mrrSwapLabel req
             , mrlpTemplateGraph     = mrcTemplateGraph catalogEntry
             , mrlpAdapterOptions    = adapterOptions
             , mrlpControlSurface    =
                 controlSurfaceFor requestedManifest
             , mrlpArbitrationPolicy = FifoOnly
             }
  where
    requestedKey = mrrDemoKey req

-- | Project a validated plan into the existing hot-swap command shape.
--
-- This does not choose when or how to install the command. Construction-time,
-- stopped-audio, and live preserving strategies can all consume the same
-- value differently.
manifestReloadCommand :: ManifestReloadPlan -> SessionCommand
manifestReloadCommand plan =
  CmdHotSwap (mrlpSwapLabel plan) (mrlpTemplateGraph plan)

-- | Apply a plan's adapter policy to caller-owned owner options.
--
-- Builder capacity and max-frame policy remain with the caller; the manifest
-- plan supplies only the adapter options derived from resource policy.
-- The plan's adapter options replace the base adapter options entirely;
-- per-template polyphony from the base is not preserved.
manifestSessionOwnerOptions
  :: SessionOwnerOptions
  -> ManifestReloadPlan
  -> SessionOwnerOptions
manifestSessionOwnerOptions base plan =
  base { sooAdapterOptions = mrlpAdapterOptions plan }

controlSurfaceFor :: AuthoringManifest -> [ManifestControlSurface]
controlSurfaceFor manifest =
  map manifestControlSurface (mfControls manifest)

manifestControlSurface :: ManifestControl -> ManifestControlSurface
manifestControlSurface c = ManifestControlSurface
  { mcsDisplayName = mcName c
  , mcsControlTag  = ControlTag (MigrationKey (mcKey c)) (mcSlot c)
  , mcsDefault     = mcDefault c
  , mcsRangeMin    = mcRangeMin c
  , mcsRangeMax    = mcRangeMax c
  , mcsSmoothingHz = mcSmoothingHz c
  , mcsCC          = mcCC c
  }

validateManifestTemplates
  :: AuthoringManifest
  -> Either ManifestReloadIssue ()
validateManifestTemplates manifest = do
  case firstDuplicate mtName (mfTemplates manifest) of
    Just dup -> Left (MriDuplicateTemplateName (TemplateName dup))
    Nothing  -> Right ()
  traverse_ validateRole (mfTemplates manifest)
  where
    validateRole t =
      case mtRole t of
        "voice" -> Right ()
        "fx"    -> Right ()
        other   -> Left (MriUnknownTemplateRole (mtName t) other)

validateCatalogTemplates
  :: AuthoringManifest
  -> TemplateGraph
  -> Either ManifestReloadIssue ()
validateCatalogTemplates manifest graph =
  traverse_ requireTemplate (mfTemplates manifest)
  where
    graphNames =
      S.fromList [ tplName tpl | tpl <- tgTemplates graph ]

    requireTemplate t =
      if S.member (mtName t) graphNames
         then Right ()
         else Left (MriCatalogMissingTemplate (TemplateName (mtName t)))

adapterOptionsFor
  :: AuthoringManifest
  -> ManifestResourcePolicy
  -> Either ManifestReloadIssue RTGraphAdapterOptions
adapterOptionsFor manifest policy = do
  first MriInvalidResourcePolicy (validateResourcePolicy policy)
  let perTemplate =
        M.fromList
          [ (name, polyphonyFor t)
          | t <- mfTemplates manifest
          , let name = TemplateName (mtName t)
          ]
  pure defaultRTGraphAdapterOptions
    { raoPerTemplatePolyphony = perTemplate
    }
  where
    polyphonyFor t =
      let name = TemplateName (mtName t)
          roleDefault =
            case mtRole t of
              "fx" -> mrpFxPolyphony policy
              _    -> mrpVoicePolyphony policy
      in M.findWithDefault roleDefault name (mrpTemplateOverrides policy)

validateResourcePolicy
  :: ManifestResourcePolicy
  -> Either ManifestResourcePolicyIssue ()
validateResourcePolicy policy
  | mrpVoicePolyphony policy <= 0 =
      Left (MrpiVoicePolyphonyNonPositive (mrpVoicePolyphony policy))
  | mrpFxPolyphony policy <= 0 =
      Left (MrpiFxPolyphonyNonPositive (mrpFxPolyphony policy))
  | Just (name, value) <- firstNonPositiveOverride =
      Left (MrpiTemplateOverrideNonPositive name value)
  | otherwise =
      Right ()
  where
    firstNonPositiveOverride =
      case [ (name, value)
           | (name, value) <- M.toList (mrpTemplateOverrides policy)
           , value <= 0
           ] of
        []      -> Nothing
        x : _   -> Just x

firstDuplicate :: Ord b => (a -> b) -> [a] -> Maybe b
firstDuplicate key =
  go S.empty
  where
    go _ [] =
      Nothing
    go seen (x : xs)
      | S.member k seen = Just k
      | otherwise       = go (S.insert k seen) xs
      where
        k = key x
