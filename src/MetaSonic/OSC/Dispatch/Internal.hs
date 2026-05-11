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
  , dropVoice
  , installTemplateGraph
  , resolveStateTemplate
  , resolveStateVoices
    -- * Dispatch outputs
  , DispatchAction (..)
  , DispatchIssue (..)
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
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Compile   (RuntimeNode (..), rgNodes)
import           MetaSonic.Bridge.Source    (MigrationKey (..))
import           MetaSonic.Bridge.Templates (Template (..), TemplateGraph (..))
import           MetaSonic.OSC.Wire         (OscArg (..), OscMessage (..))
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
-- update helpers — they are the natural place to enforce the
-- OSC-safe identifier profile and the §5.4.C re-resolution
-- discipline once a hot-swap lands.
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
registerVoice key slotId tname rs
  | key `elem` reservedOscPathSegments =
      Left (DiReservedPathSegment key)
  | not (isOscSafeIdentifier key) =
      Left (DiIdentifierProfile key)
  | otherwise =
      Right (registerVoiceUnchecked key slotId tname rs)

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

-- | Replace the active 'TemplateGraph'. The IO layer calls this
-- on hot-swap (§5.3 helpers). Voices in the table remain by key,
-- but a subsequent dispatch may surface 'DiMissingTemplateForVoice'
-- if the new ensemble does not carry the voice's template name —
-- mirroring §6.A's @HotSwapTemplateLost@ behavior.
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
  segments              <- splitAddress (oscAddr msg)
  (voiceKey, nodeTag, slotStr) <-
    case segments of
      [v, n, s] -> Right (v, n, s)
      _         -> Left (DiInvalidAddressFormat (oscAddr msg))

  when' (voiceKey `elem` reservedOscPathSegments)
        (DiReservedPathSegment voiceKey)
  when' (not (isOscSafeIdentifier voiceKey))
        (DiIdentifierProfile voiceKey)
  when' (not (isOscSafeIdentifier nodeTag))
        (DiIdentifierProfile nodeTag)

  slot <- parseSlotInteger slotStr

  (slotId, tname) <-
    case M.lookup voiceKey (_rsVoices rs) of
      Just x  -> Right x
      Nothing -> Left (DiUnknownVoice voiceKey)

  tpl <-
    case findTemplate tname (_rsTemplate rs) of
      Just t  -> Right t
      Nothing -> Left (DiMissingTemplateForVoice voiceKey tname)

  node <-
    case findNodeByTag (BSC.unpack nodeTag) tpl of
      Just n  -> Right n
      Nothing -> Left (DiUnknownNodeTag voiceKey nodeTag)

  let controlCount = length (rnControls node)
  when' (slot < 0 || slot >= controlCount)
        (DiInvalidControlSlot voiceKey nodeTag slot controlCount)

  value <-
    case oscArgs msg of
      [OscArgFloat f] -> Right (realToFrac f)
      [OscArgInt   i] -> Right (fromIntegral (i :: Int32))
      other           -> Left (DiUnsupportedArgShape (length other))

  Right DAControlWrite
    { daSlotId     = slotId
    , daNodeIndex  = rnIndex node
    , daControlIdx = slot
    , daValue      = value
    }
  where
    when' :: Bool -> DispatchIssue -> Either DispatchIssue ()
    when' True  issue = Left issue
    when' False _     = Right ()

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

findTemplate :: ByteString -> TemplateGraph -> Maybe Template
findTemplate name tg =
  case [ t | t <- tgTemplates tg, BSC.pack (tplName t) == name ] of
    (t : _) -> Just t
    []      -> Nothing

findNodeByTag :: String -> Template -> Maybe RuntimeNode
findNodeByTag tag tpl =
  case [ n | n <- rgNodes (tplGraph tpl)
           , rnMigrationKey n == Just (MigrationKey tag)
       ] of
    (n : _) -> Just n
    []      -> Nothing
