{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.OSC.Dispatch.Internal
-- Description : Phase 6.B.2a — full OSC dispatch surface (including
--               the documented unchecked-registration escape hatch).
--
-- Tests and other in-repo internal code import from here when they
-- need access to 'registerVoiceUnchecked'. Production code should
-- import 'MetaSonic.OSC.Dispatch' instead, which re-exports the
-- safe subset and never lets a caller bypass the OSC-safe
-- identifier validation.
--
-- See the §6.B design note for the rationale on splitting the
-- escape hatch into an @.Internal@ module.

module MetaSonic.OSC.Dispatch.Internal
  ( -- * Resolution state
    ResolveState
  , emptyResolveState
  , registerVoice
  , registerVoiceUnchecked
  , validateVoiceKey
  , dropVoice
  , installTemplateGraph
  , resolveStateTemplate
  , resolveStateVoices
    -- * Dispatch outputs
  , DispatchAction (..)
  , DispatchIssue (..)
  , SymbolicControlWrite (..)
  , decodeSymbolicControlWrite
  , dispatch
    -- * OSC-safe identifier profile
  , isOscSafeIdentifier
  , reservedOscPathSegments
  ) where

import           Control.DeepSeq            (NFData)
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BSC
import           Data.Int                   (Int32)
import qualified Data.Map.Strict            as M
import           GHC.Float                  (float2Double)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Source    (MigrationKey (..))
import           MetaSonic.Bridge.Templates (TemplateGraph (..))
import           MetaSonic.ControlTarget    (ControlTarget (..),
                                             ControlTargetIssue (..),
                                             resolveControlTarget)
import           MetaSonic.OSC.Wire         (OscArg (..), OscMessage (..))
import           MetaSonic.Pattern          (ControlTag (..),
                                             TemplateName (..), Value,
                                             VoiceKey (..))
import           MetaSonic.Types            (NodeIndex)

----------------------------------------------------------------------
-- Resolution state
----------------------------------------------------------------------

-- | The dispatcher's resolution table. Mirrors the §6.A
-- driver-stub state: the currently-loaded 'TemplateGraph' plus a
-- @VoiceKey → (slot_id, TemplateName)@ map. The IO layer
-- mutates this via 'registerVoice' / 'dropVoice' /
-- 'installTemplateGraph' as the runtime spawns voices, releases
-- them, and hot-swaps the ensemble.
--
-- Constructor is hidden so the IO layer is forced through the
-- update helpers. They enforce the OSC-safe identifier profile for
-- direct table edits. Session graph installs should rebuild the OSC
-- table through 'MetaSonic.Session.Resolve.rebuildResolveState' so
-- stale voice bindings are diagnosed at commit time.
data ResolveState = ResolveState
  { _rsTemplate :: !TemplateGraph
  , _rsVoices   :: !(M.Map ByteString (Int, ByteString))
    -- ^ VoiceKey → (slot_id, TemplateName). TemplateName is the
    -- 'tplName' the voice was spawned against; needed for the
    -- @(template, node-tag) → NodeIndex@ resolution.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyResolveState :: TemplateGraph -> ResolveState
emptyResolveState tg = ResolveState
  { _rsTemplate = tg
  , _rsVoices   = M.empty
  }

-- | Register a voice with OSC-safe profile validation. This is
-- the default registration entry: a non-conforming voice key
-- (reserved word, identifier-profile violation) is refused at
-- the table-write so the dispatcher's invariants hold for every
-- key it later sees. Use 'registerVoiceUnchecked' only when
-- tests or internal code genuinely need to install a key the
-- default API would refuse.
registerVoice
  :: ByteString  -- ^ voice key
  -> Int         -- ^ runtime slot id
  -> ByteString  -- ^ template name the voice was spawned against
  -> ResolveState
  -> Either DispatchIssue ResolveState
registerVoice key slotId tname rs = do
  validateVoiceKey key
  pure (registerVoiceUnchecked key slotId tname rs)

-- | Validate a voice key with the same OSC-safe profile enforced by
-- 'registerVoice', without mutating a 'ResolveState'.
validateVoiceKey :: ByteString -> Either DispatchIssue ()
validateVoiceKey key
  | key `elem` reservedOscPathSegments =
      Left (DiReservedPathSegment key)
  | not (isOscSafeIdentifier key) =
      Left (DiIdentifierProfile key)
  | otherwise =
      Right ()

-- | Register a voice without validation. Documented escape
-- hatch: callers must ensure the voice key is OSC-safe
-- themselves, or accept that the voice is reachable in the
-- internal table but unreachable from any OSC path. Used by
-- tests that exercise the dispatch layer's defense-in-depth
-- against malformed table state; production code should call
-- 'registerVoice'.
registerVoiceUnchecked
  :: ByteString  -- ^ voice key
  -> Int         -- ^ runtime slot id
  -> ByteString  -- ^ template name the voice was spawned against
  -> ResolveState
  -> ResolveState
registerVoiceUnchecked key slotId tname rs =
  rs { _rsVoices = M.insert key (slotId, tname) (_rsVoices rs) }

dropVoice :: ByteString -> ResolveState -> ResolveState
dropVoice key rs =
  rs { _rsVoices = M.delete key (_rsVoices rs) }

-- | Low-level replacement helper for the active 'TemplateGraph'.
-- Existing voice bindings remain by key, so a subsequent dispatch may
-- surface 'DiMissingTemplateForVoice' if the new ensemble does not
-- carry a voice's template name. Session hot-swap code should prefer
-- 'MetaSonic.Session.Resolve.rebuildResolveState' when it wants stale
-- bindings dropped and reported during the commit.
installTemplateGraph :: TemplateGraph -> ResolveState -> ResolveState
installTemplateGraph tg rs = rs { _rsTemplate = tg }

resolveStateTemplate :: ResolveState -> TemplateGraph
resolveStateTemplate = _rsTemplate

resolveStateVoices :: ResolveState -> M.Map ByteString (Int, ByteString)
resolveStateVoices = _rsVoices

----------------------------------------------------------------------
-- Outputs
----------------------------------------------------------------------

-- | The single v1 dispatch outcome: write a value to a
-- (slot, node, control-slot) target through the realtime queue.
-- The IO layer turns this into a
-- @rt_graph_realtime_set_control@ call.
data DispatchAction = DAControlWrite
  { daSlotId     :: !Int
  , daNodeIndex  :: !NodeIndex
  , daControlIdx :: !Int
  , daValue      :: !Double
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | A decoded symbolic OSC control write, before any runtime
-- 'ResolveState' lookup. This is the shared parser shape for
-- producer/session adapters that need to accept the same
-- @/<voice>/<tag>/<slot>@ + numeric-value grammar as 'dispatch'
-- without resolving to runtime slot and node indices.
data SymbolicControlWrite = SymbolicControlWrite
  { scwVoiceKey   :: !VoiceKey
  , scwControlTag :: !ControlTag
  , scwValue      :: !Value
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Everything a v1 dispatch can refuse. Modeled on §6.A's
-- 'DriverIssue' so the IO layer's log lines look familiar.
data DispatchIssue
  = DiInvalidAddressFormat   !ByteString
    -- ^ Address does not match @/<voice>/<tag>/<slot>@.
  | DiReservedPathSegment    !ByteString
    -- ^ Voice key equals one of 'reservedOscPathSegments'
    -- (@on@, @off@, @swap@).
  | DiIdentifierProfile      !ByteString
    -- ^ Voice key or node tag falls outside the OSC-safe
    -- profile ('isOscSafeIdentifier').
  | DiSlotNotInteger         !ByteString
    -- ^ The third path segment is not a plain non-negative
    -- decimal integer.
  | DiUnknownVoice           !ByteString
    -- ^ Voice key is not currently registered in the resolve
    -- state.
  | DiMissingTemplateForVoice !ByteString !ByteString
    -- ^ The voice's registered template name is no longer
    -- present in the active 'TemplateGraph' (post-hot-swap
    -- orphan). Fields: voice key, template name.
  | DiUnknownNodeTag         !ByteString !ByteString
    -- ^ No node in the voice's template carries the given
    -- 'MigrationKey'. Fields: voice key, node tag.
  | DiInvalidControlSlot     !ByteString !ByteString !Int !Int
    -- ^ Slot is out of range for the resolved node. Fields:
    -- voice key, node tag, requested slot, the node's control
    -- count.
  | DiUnsupportedArgShape    !Int
    -- ^ v1 expects exactly one argument (float or int). Field:
    -- the actual count.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

----------------------------------------------------------------------
-- OSC-safe identifier profile
----------------------------------------------------------------------

-- | Identifiers used as OSC path segments must be ASCII letters,
-- digits, underscore, or hyphen, non-empty, and ≤16 UTF-8 bytes.
-- See the §6.B design note for the rationale.
isOscSafeIdentifier :: ByteString -> Bool
isOscSafeIdentifier bs =
  let len = BS.length bs
      ok c = (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c == '_' || c == '-'
  in len > 0 && len <= 16 && BSC.all ok bs

-- | Path segments that may not be used as voice keys, reserved
-- for the deferred voice-lifecycle and hot-swap grammars.
reservedOscPathSegments :: [ByteString]
reservedOscPathSegments =
  [ BSC.pack "on"
  , BSC.pack "off"
  , BSC.pack "swap"
  ]

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------

-- | Resolve a parsed OSC message against the dispatcher's state.
-- v1 grammar is control-writes-only; anything else is a
-- 'DiInvalidAddressFormat'.
dispatch :: ResolveState -> OscMessage -> Either DispatchIssue DispatchAction
dispatch rs msg = do
  DecodedControlAddress voiceKey nodeTag controlTag <-
    decodeControlAddress (oscAddr msg)

  (slotId, tname) <-
    case M.lookup voiceKey (_rsVoices rs) of
      Just x  -> Right x
      Nothing -> Left (DiUnknownVoice voiceKey)

  target <-
    case resolveControlTarget
           (_rsTemplate rs)
           (TemplateName (BSC.unpack tname))
           controlTag of
      Right x    -> Right x
      Left issue -> Left (toDispatchIssue voiceKey nodeTag tname issue)

  value <- decodeControlValue (oscArgs msg)

  Right DAControlWrite
    { daSlotId     = slotId
    , daNodeIndex  = targetNodeIndex target
    , daControlIdx = targetControlSlot target
    , daValue      = value
    }
  where
    toDispatchIssue
      :: ByteString -> ByteString -> ByteString -> ControlTargetIssue
      -> DispatchIssue
    toDispatchIssue voiceKey nodeTag tname issue = case issue of
      CtiMissingTemplate _ ->
        DiMissingTemplateForVoice voiceKey tname
      CtiUnknownNodeTag {} ->
        DiUnknownNodeTag voiceKey nodeTag
      CtiInvalidControlSlot _ _ requested available ->
        DiInvalidControlSlot voiceKey nodeTag requested available

-- | Decode the v1 symbolic OSC control-write grammar without
-- consulting runtime state. This intentionally stops at the
-- producer-facing identifiers: later session code can turn the result
-- into a 'MetaSonic.Session.Command.CmdControlWrite', while the
-- legacy OSC dispatcher resolves the same address through
-- 'ResolveState' before enqueueing the realtime write.
decodeSymbolicControlWrite
  :: OscMessage -> Either DispatchIssue SymbolicControlWrite
decodeSymbolicControlWrite msg = do
  DecodedControlAddress voiceKey _ controlTag <-
    decodeControlAddress (oscAddr msg)
  value <- decodeControlValue (oscArgs msg)
  Right SymbolicControlWrite
    { scwVoiceKey   = VoiceKey (BSC.unpack voiceKey)
    , scwControlTag = controlTag
    , scwValue      = value
    }

data DecodedControlAddress =
  DecodedControlAddress !ByteString !ByteString !ControlTag
  deriving stock (Eq, Show)

decodeControlAddress
  :: ByteString -> Either DispatchIssue DecodedControlAddress
decodeControlAddress addr = do
  segments <- splitAddress addr
  (voiceKey, nodeTag, slotStr) <-
    case segments of
      [v, n, s] -> Right (v, n, s)
      _         -> Left (DiInvalidAddressFormat addr)

  when' (voiceKey `elem` reservedOscPathSegments)
        (DiReservedPathSegment voiceKey)
  when' (not (isOscSafeIdentifier voiceKey))
        (DiIdentifierProfile voiceKey)
  when' (not (isOscSafeIdentifier nodeTag))
        (DiIdentifierProfile nodeTag)

  slot <- parseSlotInteger slotStr
  Right $
    DecodedControlAddress
      voiceKey
      nodeTag
      (ControlTag (MigrationKey (BSC.unpack nodeTag)) slot)
  where
    when' :: Bool -> DispatchIssue -> Either DispatchIssue ()
    when' True  issue = Left issue
    when' False _     = Right ()

decodeControlValue :: [OscArg] -> Either DispatchIssue Value
decodeControlValue args = case args of
  [OscArgFloat f] -> Right (float2Double f)
  [OscArgInt   i] -> Right (fromIntegral (i :: Int32))
  other           -> Left (DiUnsupportedArgShape (length other))

splitAddress :: ByteString -> Either DispatchIssue [ByteString]
splitAddress addr = case BSC.uncons addr of
  Just ('/', rest) ->
    let parts = BSC.split '/' rest
    in if null parts || any BS.null parts
         then Left (DiInvalidAddressFormat addr)
         else Right parts
  _ -> Left (DiInvalidAddressFormat addr)

-- | Parse a slot path segment. Accepts decimal digits only,
-- non-negative, no leading sign or whitespace.
parseSlotInteger :: ByteString -> Either DispatchIssue Int
parseSlotInteger bs
  | BS.null bs            = Left (DiSlotNotInteger bs)
  | not (BSC.all isAsciiDigit bs) = Left (DiSlotNotInteger bs)
  | otherwise             = case BSC.readInt bs of
      Just (n, rest) | BS.null rest && n >= 0 -> Right n
      _                                       -> Left (DiSlotNotInteger bs)
  where
    isAsciiDigit c = c >= '0' && c <= '9'
