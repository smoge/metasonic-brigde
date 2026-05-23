{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.App.ManifestLiveValueCache
-- Description : App-local cache of last accepted control target values for
--               the manifest live-session shell (Phase 8h).
--
-- This module is the pure substrate behind the live-session @values@
-- command. It records the last 'CmdControlWrite' value accepted by the
-- live session for each @(VoiceKey, ControlTag)@ pair and lets a thin
-- IO layer wrap it in an 'IORef' inside
-- 'MetaSonic.App.ManifestLiveSession'.
--
-- Design contract:
--
--   * The cache is /producer-neutral/. An accepted write is an accepted
--     write regardless of whether the originating packet came in over
--     OSC, MIDI CC, or a UI producer. The cache update path takes
--     @VoiceKey -> ControlTag -> Value@ and never branches on ingress.
--
--   * The cache is /target/, not DSP. The recorded value is what the
--     session shell saw an 'SessionEnqueued' 'CmdControlWrite' carry —
--     the same number the transcript already prints on an
--     @osc accept: ... value=...@ line. It is not sample-accurate
--     runtime state and never reads back from the C++ runtime.
--
--   * Manifest defaults are /not/ cached. The renderer derives
--     @source=default@ from a manifest binding when there is no
--     accepted entry for a given @(VoiceKey, ControlTag)@; the cache
--     only carries the entries the session actually observed.
--
-- See @notes/2026-05-22-g-live-control-value-introspection-design.md@
-- for the lane this slice implements.
module MetaSonic.App.ManifestLiveValueCache
  ( -- * Types
    LiveValueCache
  , LiveControlValue (..)
  , LiveControlValueSource (..)
    -- * Cache operations
  , emptyLiveValueCache
  , recordAcceptedWrite
  , retainSurvivingControls
  , lookupLiveValue
    -- * Rendering
  , renderValuesTable
  ) where

import qualified Data.Map.Strict as M
import           Data.Set        (Set)
import qualified Data.Set        as Set

import           MetaSonic.App.ManifestLiveCommon
                                   (renderConcreteOSCAddress,
                                    renderOperatorValue)
import           MetaSonic.App.ManifestReloadOSCBinding
                                   (ManifestOSCControlBinding (..))
import           MetaSonic.Pattern (ControlTag, VoiceKey, Value)


-- | Provenance of one cached value.
--
-- The renderer also synthesises a third 'source=' string (@default@)
-- when no cache entry exists for a control; that synthesis happens at
-- render time and does not need a constructor here.
data LiveControlValueSource
  = LcvsAccepted
    -- ^ Last 'CmdControlWrite' accepted by the live session shell for
    --   this voice/control. Source-agnostic: OSC, MIDI CC, or UI
    --   accepted writes all land here.
  deriving stock (Eq, Show)


-- | One cached value plus its provenance.
data LiveControlValue = LiveControlValue
  { lcvValue  :: !Value
  , lcvSource :: !LiveControlValueSource
  } deriving stock (Eq, Show)


-- | The per-shell value cache. Voice-major, control-minor.
--
-- An empty entry for a voice is observationally identical to no entry;
-- the renderer derives defaults from the manifest binding when a
-- @(voice, control)@ pair is missing.
type LiveValueCache = M.Map VoiceKey (M.Map ControlTag LiveControlValue)


-- | Empty cache. Used at session start and on full resets.
emptyLiveValueCache :: LiveValueCache
emptyLiveValueCache = M.empty


-- | Record one accepted 'CmdControlWrite'. The new value overwrites
-- any prior entry for the same @(voice, control)@.
--
-- This is the producer-neutral hook the design note specifies: any
-- accepted-write path (OSC today, MIDI/UI when a shared seam is
-- wired) calls this updater with the same shape.
recordAcceptedWrite
  :: VoiceKey
  -> ControlTag
  -> Value
  -> LiveValueCache
  -> LiveValueCache
recordAcceptedWrite voice tag value =
  M.alter insertEntry voice
  where
    insertEntry = \case
      Nothing      -> Just (M.singleton tag entry)
      Just inner   -> Just (M.insert tag entry inner)
    entry = LiveControlValue { lcvValue = value, lcvSource = LcvsAccepted }


-- | After a preserving reload commits, drop any cached entries whose
-- 'ControlTag' no longer exists on the new current target. Surviving
-- tags keep their accepted values; tags newly introduced by the new
-- plan have no cache entry yet and will render @source=default@.
--
-- Voices that no longer exist on the new plan are also dropped — the
-- caller supplies the surviving voice set.
retainSurvivingControls
  :: Set VoiceKey
  -> Set ControlTag
  -> LiveValueCache
  -> LiveValueCache
retainSurvivingControls survivingVoices survivingTags cache =
  M.mapMaybeWithKey keepVoice cache
  where
    keepVoice voice inner
      | voice `Set.member` survivingVoices =
          let kept = M.filterWithKey (\tag _ -> tag `Set.member` survivingTags) inner
          in if M.null kept then Nothing else Just kept
      | otherwise = Nothing


-- | Look up one value. Used by tests and by call sites that want a
-- single entry without rendering the whole table.
lookupLiveValue
  :: VoiceKey
  -> ControlTag
  -> LiveValueCache
  -> Maybe LiveControlValue
lookupLiveValue voice tag cache = do
  inner <- M.lookup voice cache
  M.lookup tag inner


-- | Render the operator-facing @values@ table for one demo's current
-- (voice × manifest control) cross product.
--
-- Output shape (one block per voice):
--
-- @
--   values for \<demo-key\>:
--     \<voice-empty-or-rows\>
-- @
--
-- Each row reads
--
-- @
--     \/v0\/lpf\/0  name="cutoff" value=1800 source=accepted default=600.0 range=[200.0, 6000.0] cc=74
-- @
--
-- Missing entries render as @source=default@ with the manifest
-- default value. The value half reuses 'renderOperatorValue', so the
-- format matches OSC accept lines (@0.05@ → @5e-2@ etc.).
--
-- The address column is padded to the widest concrete address in the
-- table so columns align visually for a four-control fixture.
renderValuesTable
  :: String
  -> [VoiceKey]
  -> [ManifestOSCControlBinding]
  -> LiveValueCache
  -> [String]
renderValuesTable demoKey voices bindings cache = case (voices, bindings) of
  ([], _) ->
    [ header
    , "    (no live voices)"
    ]
  (_, []) ->
    [ header
    , "    (manifest binds no OSC controls)"
    ]
  _ ->
    header : concatMap renderVoiceBlock voices
  where
    header = "  values for " <> demoKey <> ":"

    -- Preserve manifest order so 'values' rows visually line up
    -- with 'controls' / 'addressable OSC surface' / startup
    -- preamble. 'motControls' contracts manifest order for
    -- diagnostics (see Note on 'ManifestOSCIngressTarget' in
    -- ManifestReloadOSCBinding.hs); 'printAddressableSurface' walks
    -- the same list in the same order. Sorting here would silently
    -- disagree with both surfaces.

    -- Safe because the outer 'case' returns early when voices or
    -- bindings is empty, so this list is non-empty.
    addressWidth =
      maximum
        [ length (renderConcreteOSCAddress voice (mocbControlTag binding))
        | voice <- voices
        , binding <- bindings
        ]

    renderVoiceBlock voice =
      map (renderRow voice) bindings

    renderRow voice binding =
      let address  = renderConcreteOSCAddress voice (mocbControlTag binding)
          padded   = address <> replicate (addressWidth - length address) ' '
          metadata = " name=\"" <> mocbDisplayName binding <> "\""
          (valueStr, sourceStr) = case lookupLiveValue voice (mocbControlTag binding) cache of
            Just lcv ->
              ( renderOperatorValue (lcvValue lcv)
              , renderSource (lcvSource lcv)
              )
            Nothing ->
              ( renderOperatorValue (mocbDefault binding)
              , "default"
              )
      in "    " <> padded
         <> metadata
         <> " value=" <> valueStr
         <> " source=" <> sourceStr
         <> " default=" <> show (mocbDefault binding)
         <> " range=[" <> show (mocbRangeMin binding)
         <> ", " <> show (mocbRangeMax binding) <> "]"
         <> ccSuffix binding

    ccSuffix binding = case mocbCC binding of
      Nothing -> ""
      Just cc -> " cc=" <> show cc

    renderSource = \case
      LcvsAccepted -> "accepted"
