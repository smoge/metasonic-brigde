{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Pattern
-- Description : Phase 6.A.2 — Pattern contract (symbolic producer events).
--
-- A 'Pattern' is a pure producer of timed symbolic events plus the
-- pre-compiled initial 'TemplateGraph' a driver loads at pattern
-- start. The pattern never names runtime instance slots, swap
-- generations, or other identifiers the audio thread assigns; a
-- driver layer (not shipped in 6.A.2) translates symbolic events
-- into the realtime ABI surface.
--
-- See [Phase 6.A pattern design](../../../notes/2026-05-10-phase-6a-pattern-design.md)
-- and [Phase 6.A.2 contract and corpus](../../../notes/2026-05-10-phase-6a2-pattern-corpus-design.md).

module MetaSonic.Pattern
  ( -- * Symbolic identifiers
    TemplateName (..)
  , VoiceKey (..)
  , ControlTag (..)
  , SwapLabel (..)
  , Value
    -- * Time
  , SamplePos (..)
  , SampleRange (..)
  , sampleRangeContains
    -- * Events
  , PatternEvent (..)
    -- * Pattern
  , Pattern (..)
  , expandPattern
  , staticEvents
  ) where

import           Control.DeepSeq            (NFData)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Source    (MigrationKey)
import           MetaSonic.Bridge.Templates (TemplateGraph)

-- | Symbolic template name. Resolved by the driver against the
-- pattern's pre-compiled 'TemplateGraph' (matching 'tplName').
newtype TemplateName = TemplateName { unTemplateName :: String }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Pattern-local stable voice identity. Two events sharing a
-- 'VoiceKey' refer to the same logical voice across 'PEVoiceOn',
-- 'PEVoiceOff', and 'PEControlWrite'. The driver assigns runtime
-- slot identity; the pattern only emits keys.
newtype VoiceKey = VoiceKey { unVoiceKey :: String }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Symbolic @(NodeTag, ControlSlot)@ target. The 'NodeTag' reuses
-- the §5.2 'MigrationKey' shape so a producer that already marks
-- nodes for state migration gets pattern-level control targeting
-- for free.
data ControlTag = ControlTag
  { ctNodeTag :: !MigrationKey
  , ctSlot    :: !Int
  } deriving stock    (Eq, Ord, Show, Generic)
    deriving anyclass (NFData)

-- | Producer-readable label naming a swap event for audit /
-- @--swap-bench@ reporting. Not load-bearing for ABI resolution.
newtype SwapLabel = SwapLabel { unSwapLabel :: String }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Control values land on the realtime queue as 'Double', matching
-- the existing @rt_graph_realtime_set_control@ surface.
type Value = Double

-- | Pattern-time as a discrete sample position relative to the
-- pattern's zero. The v1 driver delivers events at block
-- boundaries; sub-block precision is contract-permitted but
-- unused by the v1 verification gate.
newtype SamplePos = SamplePos { unSamplePos :: Int }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Half-open sample range @[srStart, srEnd)@.
data SampleRange = SampleRange
  { srStart :: !SamplePos
  , srEnd   :: !SamplePos
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | @True@ iff @pos ∈ [srStart, srEnd)@.
sampleRangeContains :: SampleRange -> SamplePos -> Bool
sampleRangeContains (SampleRange (SamplePos t0) (SamplePos t1)) (SamplePos p) =
  p >= t0 && p < t1

-- | Symbolic pattern event. Patterns emit only symbolic
-- identifiers; the driver resolves to realtime ABI primitives.
data PatternEvent
  = PEVoiceOn      !TemplateName !VoiceKey ![(ControlTag, Value)]
    -- ^ Trigger a voice of the named template, identifying it
    -- with a pattern-local 'VoiceKey' and supplying its initial
    -- control values. Driver: reserve → set_control (while
    -- Reserved) → activate; records @VoiceKey → slot_id@.
  | PEVoiceOff     !VoiceKey
    -- ^ Release the named voice. Driver: look up the slot and
    -- call @rt_graph_realtime_release@. Slot reuse follows §2.E
    -- release-then-free; the pattern does not see @Remove@.
  | PEControlWrite !VoiceKey !ControlTag !Value
    -- ^ Update a control on a live voice. Driver: resolve
    -- @(VoiceKey, ControlTag)@ to @(slot_id, node_index,
    -- control_slot)@ and call @rt_graph_realtime_set_control@.
  | PEHotSwap      !SwapLabel !TemplateGraph
    -- ^ Publish a pre-compiled replacement ensemble. Driver:
    -- read current generation, call the appropriate §5.3 helper,
    -- wait for install, collect retired stats.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A 'Pattern' is a deterministic, pure producer of timed
-- symbolic events plus the pre-compiled initial ensemble the
-- driver loads at pattern start.
--
-- 'patternTemplates' carries every template the driver compiles
-- and loads up front. Swap targets are embedded inline in
-- 'PEHotSwap' events (each event carries its own pre-compiled
-- 'TemplateGraph'), so every template the pattern ever references
-- is compiled before any audio thread sees it. Compile errors
-- surface at pattern construction, never on the realtime path.
--
-- 'patternEvents' is a deterministic pure function: given a
-- 'SampleRange', return the events that fall inside it, in
-- non-decreasing 'SamplePos' order. No 'IO', no mutable state, no
-- implicit randomness; patterns that need randomness take an
-- explicit seed through their constructor.
--
-- 'Pattern' has no 'Eq'/'Show'/'NFData' instance because of the
-- function field. Tests compare /expanded/ event lists instead.
data Pattern = Pattern
  { patternTemplates :: !TemplateGraph
  , patternEvents    :: SampleRange -> [(SamplePos, PatternEvent)]
  }

-- | Defensively clamp the result of 'patternEvents' to @[srStart,
-- srEnd)@. The contract requires each pattern's 'patternEvents' to
-- already restrict its output to events inside the requested range
-- (see 'staticEvents' for the canonical static-pattern realization);
-- the clamp here is a safety net so a buggy row that ignores the
-- range cannot silently mislead a downstream driver. No other
-- validation: 'SamplePos' ordering and 'VoiceKey' lifecycle
-- invariants are checked by the driver-stub validator in tests, not
-- here.
expandPattern :: Pattern -> SampleRange -> [(SamplePos, PatternEvent)]
expandPattern p r =
  filter (sampleRangeContains r . fst) (patternEvents p r)

-- | Canonical 'patternEvents' implementation for static patterns:
-- the full event list is fixed at construction time, and the
-- emitter returns only the entries whose 'SamplePos' falls inside
-- the requested range. Realizes the strict reading of the contract
-- (@patternEvents r@ returns events inside @r@), so a driver that
-- calls 'patternEvents' directly each audio block sees only the
-- events that block needs.
staticEvents
  :: [(SamplePos, PatternEvent)]
  -> SampleRange
  -> [(SamplePos, PatternEvent)]
staticEvents events r = filter (sampleRangeContains r . fst) events
