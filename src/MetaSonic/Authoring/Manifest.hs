{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : MetaSonic.Authoring.Manifest
-- Description : Phase 8.H — JSON manifest of a demo's authoring surface
--
-- A small, export-only JSON view derived from
-- 'MetaSonic.Authoring.Report.AuthoringReport'. The manifest
-- captures what an authoring layer asked for — templates,
-- roles, named buses, named controls, ranges, CC bindings,
-- migration keys — *not* the lowered 'SynthGraph'. Anyone
-- who needs the graph back must rebuild it from source.
--
-- The contract:
--
--   * 'manifestSchemaVersion' is @1@ today. Decoders refuse
--     other versions; encoders always emit version 1.
--   * Wire field names are user-readable
--     (@"templates"@, @"role"@, @"cc"@) — not the Haskell
--     record-field names. Explicit 'ToJSON' / 'FromJSON'
--     instances keep the wire shape under control.
--   * Round-trip is semantic, not byte-equal. Whitespace
--     and key ordering are not load-bearing.
--   * No timestamps, hostnames, or environment fields. The
--     manifest for an in-repo demo must be byte-stable
--     across machines.
--
-- See [notes/2026-05-12-phase-8h-authoring-manifest.md].

module MetaSonic.Authoring.Manifest
  ( -- * Schema version
    manifestSchemaVersion

    -- * Document
  , AuthoringManifestDoc (..)

    -- * Per-demo manifest
  , AuthoringManifest (..)
  , ManifestTemplate (..)
  , ManifestBus (..)
  , ManifestControl (..)

    -- * Projection
  , manifestFromReport

    -- * Encoding / decoding
  , encodeManifestDoc
  , decodeManifestDoc
  ) where

import           Data.Aeson           (FromJSON (..), ToJSON (..), Value (..),
                                       (.:), (.:?), (.=), object, withObject,
                                       eitherDecode)
import           Data.Aeson.Encode.Pretty (Config (..), Indent (..),
                                            NumberFormat (..), defConfig,
                                            encodePretty', keyOrder)
import qualified Data.ByteString.Lazy as BL
import           Data.Word            (Word8)

import qualified MetaSonic.Authoring          as Auth
import           MetaSonic.Authoring.Report
import           MetaSonic.Bridge.Source      (MigrationKey (..))


-- | Bump this when the wire shape changes incompatibly.
-- A 'FromJSON' instance that sees a different value
-- refuses to decode.
manifestSchemaVersion :: Int
manifestSchemaVersion = 1

-- | A complete manifest document: the schema version plus
-- one entry per demo. One document per CLI invocation.
data AuthoringManifestDoc = AuthoringManifestDoc
  { docSchemaVersion :: !Int
  , docDemos         :: ![AuthoringManifest]
  } deriving (Eq, Show)

-- | One demo's authoring view.
data AuthoringManifest = AuthoringManifest
  { mfDemoKey   :: !String
  , mfTemplates :: ![ManifestTemplate]
  , mfBuses     :: ![ManifestBus]
  , mfControls  :: ![ManifestControl]
  } deriving (Eq, Show)

data ManifestTemplate = ManifestTemplate
  { mtName :: !String
  , mtRole :: !String
    -- ^ @"voice"@ or @"fx"@. A string (rather than a
    -- Haskell enum on the wire) so adding a future role
    -- doesn't force a schema bump on every old consumer.
  } deriving (Eq, Show)

data ManifestBus = ManifestBus
  { mbName  :: !String
  , mbIndex :: !Int
  } deriving (Eq, Show)

data ManifestControl = ManifestControl
  { mcName        :: !String
  , mcDefault     :: !Double
  , mcRangeMin    :: !Double
  , mcRangeMax    :: !Double
  , mcSmoothingHz :: !Double
  , mcCC          :: !(Maybe Word8)
  , mcKey         :: !String
    -- ^ The migration-key bytes as a 'String'. UTF-8
    -- spelling is the same as on the Haskell side; the
    -- runtime treats these bytes as opaque identity.
  , mcSlot        :: !Int
  } deriving (Eq, Show)

------------------------------------------------------------
-- Projection
------------------------------------------------------------

-- | Build a manifest entry from a demo key plus its
-- 'AuthoringReport'. Strict transcription — template,
-- bus, and control ordering is whatever the report
-- already encodes.
manifestFromReport :: String -> AuthoringReport -> AuthoringManifest
manifestFromReport demoKey r = AuthoringManifest
  { mfDemoKey   = demoKey
  , mfTemplates =
      [ ManifestTemplate
          { mtName = rtName t
          , mtRole = roleToString (rtRole t)
          }
      | t <- arTemplates r
      ]
  , mfBuses =
      [ ManifestBus
          { mbName  = rbName b
          , mbIndex = rbIndex b
          }
      | b <- arBuses r
      ]
  , mfControls =
      [ ManifestControl
          { mcName        = rcName c
          , mcDefault     = rcDefault c
          , mcRangeMin    = fst (rcRange c)
          , mcRangeMax    = snd (rcRange c)
          , mcSmoothingHz = rcSmoothingHz c
          , mcCC          = rcCC c
          , mcKey         = unMigrationKey (rcKey c)
          , mcSlot        = rcSlot c
          }
      | c <- arControls r
      ]
  }

roleToString :: Auth.TemplateRole -> String
roleToString Auth.VoiceTemplate = "voice"
roleToString Auth.FxTemplate    = "fx"

roleFromString :: String -> Either String Auth.TemplateRole
roleFromString "voice" = Right Auth.VoiceTemplate
roleFromString "fx"    = Right Auth.FxTemplate
roleFromString other   =
  Left $ "manifest: unknown template role '" <> other <> "'"

------------------------------------------------------------
-- JSON instances
------------------------------------------------------------

instance ToJSON ManifestTemplate where
  toJSON t = object
    [ "name" .= mtName t
    , "role" .= mtRole t
    ]

instance FromJSON ManifestTemplate where
  parseJSON = withObject "ManifestTemplate" $ \o -> do
    name <- o .:  "name"
    role <- o .:  "role"
    -- Reject unknown roles eagerly. roleFromString returns
    -- Either, but we just need to fail the parse on Left.
    case roleFromString role of
      Right _  -> pure ()
      Left err -> fail err
    pure ManifestTemplate { mtName = name, mtRole = role }

instance ToJSON ManifestBus where
  toJSON b = object
    [ "name"  .= mbName b
    , "index" .= mbIndex b
    ]

instance FromJSON ManifestBus where
  parseJSON = withObject "ManifestBus" $ \o ->
    ManifestBus
      <$> o .: "name"
      <*> o .: "index"

instance ToJSON ManifestControl where
  toJSON c = object
    [ "name"        .= mcName c
    , "default"     .= mcDefault c
    , "rangeMin"    .= mcRangeMin c
    , "rangeMax"    .= mcRangeMax c
    , "smoothingHz" .= mcSmoothingHz c
    , "cc"          .= mcCC c
    , "key"         .= mcKey c
    , "slot"        .= mcSlot c
    ]

instance FromJSON ManifestControl where
  parseJSON = withObject "ManifestControl" $ \o ->
    ManifestControl
      <$> o .:  "name"
      <*> o .:  "default"
      <*> o .:  "rangeMin"
      <*> o .:  "rangeMax"
      <*> o .:  "smoothingHz"
      <*> o .:? "cc"
      <*> o .:  "key"
      <*> o .:  "slot"

instance ToJSON AuthoringManifest where
  toJSON m = object
    [ "demo"      .= mfDemoKey m
    , "templates" .= mfTemplates m
    , "buses"     .= mfBuses m
    , "controls"  .= mfControls m
    ]

instance FromJSON AuthoringManifest where
  parseJSON = withObject "AuthoringManifest" $ \o ->
    AuthoringManifest
      <$> o .: "demo"
      <*> o .: "templates"
      <*> o .: "buses"
      <*> o .: "controls"

instance ToJSON AuthoringManifestDoc where
  toJSON d = object
    [ "schemaVersion" .= docSchemaVersion d
    , "demos"         .= docDemos d
    ]

instance FromJSON AuthoringManifestDoc where
  parseJSON = withObject "AuthoringManifestDoc" $ \o -> do
    -- Require schemaVersion be present (no .:?) so a doc
    -- missing the field rejects cleanly.
    sv <- o .: "schemaVersion"
    if sv /= manifestSchemaVersion
      then fail $
        "manifest: unsupported schemaVersion "
        <> show (sv :: Int)
        <> " (expected " <> show manifestSchemaVersion <> ")"
      else AuthoringManifestDoc sv <$> o .: "demos"

------------------------------------------------------------
-- Encoding helpers
------------------------------------------------------------

-- | Pretty-print a manifest document. Key order is chosen
-- so the most informative fields land first.
encodeManifestDoc :: AuthoringManifestDoc -> BL.ByteString
encodeManifestDoc = encodePretty' prettyConfig

prettyConfig :: Config
prettyConfig = defConfig
  { confIndent          = Spaces 2
  , confCompare         = keyOrder
      [ "schemaVersion"
      , "demos"
      , "demo"
      , "templates"
      , "buses"
      , "controls"
      , "name"
      , "role"
      , "index"
      , "default"
      , "rangeMin"
      , "rangeMax"
      , "smoothingHz"
      , "cc"
      , "key"
      , "slot"
      ]
  , confNumFormat       = Generic
  , confTrailingNewline = True
  }

-- | Parse a manifest document. Rejects unsupported schema
-- versions with a non-empty error.
decodeManifestDoc :: BL.ByteString -> Either String AuthoringManifestDoc
decodeManifestDoc = eitherDecode
