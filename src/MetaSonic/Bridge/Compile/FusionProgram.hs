{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : MetaSonic.Bridge.Compile.FusionProgram
-- Description : Phase 7.D generated-fusion program ABI (data model)
--
-- A generated-fusion 'FusionProgram' is a small, ordered list of
-- 'FusionOp's that the C++ tiny executor runs per sample for one
-- 'RuntimeRegion'. This module is the data-model scaffold for
-- Phase 7.D step 2: pure types only, no compilation pass, no FFI,
-- no planner integration.
--
-- See @notes/2026-05-12-phase-7d-runtime-program-abi.md@ for the
-- decision contract — in particular:
--
--   * Generated execution is a /fourth/ runtime path, distinct
--     from node-loop, hand-written kernel, and 'RFused'. The data
--     types here do not extend 'RegionKernel'; integration with
--     'RuntimeRegion' is a follow-up slice that adds a
--     'RegionExec' selector.
--
--   * The v1 op set is intentionally narrow: scalar/control loads,
--     input-buffer reads, add, multiply, and sink writes. Stateful
--     sources, filters, latency-bearing kinds, bus reads beyond the
--     terminal sink, buffer/plugin paths, and feedback are all out
--     of scope.
--
--   * Equivalence with 'RNodeLoop' on a hand-authored program is
--     the verification target for the slice. Profitability is not
--     measured until a later cost-lab fourth variant lands.

module MetaSonic.Bridge.Compile.FusionProgram
  ( -- * Identifiers
    FusionProgramId (..)
  , ScratchIndex (..)
    -- * Programs and ops
  , FusionProgram (..)
  , FusionOp (..)
  , FusionSource (..)
  , SinkPolicy (..)
    -- * Convenience
  , emptyFusionProgram
  , programOpCount
  ) where

import           Control.DeepSeq (NFData)
import           GHC.Generics    (Generic)

import           MetaSonic.Types (ControlIndex, NodeIndex, PortIndex)


-- | Dense identifier for one generated fusion program in a
-- 'RuntimeGraph''s program table. Survives into the C++ runtime
-- as a plain integer index; the table is built load-side and
-- consulted by region dispatch.
newtype FusionProgramId = FusionProgramId Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)


-- | A scratch slot index within one fusion program. Scratch slots
-- hold intermediate values across ops in the same program;
-- programs do not share scratch with each other, and the executor
-- reuses the same scratch array each sample.
newtype ScratchIndex = ScratchIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)


-- | One generated fusion program: an ordered list of ops plus the
-- count of scratch slots the program needs.
--
-- 'fpScratchSlots' is the high-water-mark scratch slot index plus
-- one. The executor allocates one float per scratch slot per
-- program at load time; no audio-thread allocation.
data FusionProgram = FusionProgram
  { fpOps          :: ![FusionOp]
  , fpScratchSlots :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)


-- | The v1 op set, executed in program order per sample.
--
-- Each op either writes to a 'ScratchIndex' (the "load" and
-- arithmetic ops) or to an output bus index ('OpSinkWrite').
-- Sink-write ops terminate a chain in the same way 'KOut' /
-- 'KBusOut' terminate the node graph; nothing reads from a
-- sink-written value within the same program.
data FusionOp
  = OpLoadConst !ScratchIndex !Double
    -- ^ @scratch[i] := k@. The interpreter emits a literal float.
    -- The source-operand form 'SrcConst' can also be used directly
    -- in arithmetic ops; 'OpLoadConst' exists so longer programs
    -- can stage a constant into scratch when several ops would
    -- otherwise repeat it.

  | OpLoadInput !ScratchIndex !NodeIndex !PortIndex
    -- ^ @scratch[i] := <output of node n, port p, current sample>@.
    -- The referenced node must have produced its output earlier
    -- in the same render block (no feedback in v1).

  | OpAdd       !ScratchIndex !FusionSource !FusionSource
    -- ^ @scratch[i] := a + b@.

  | OpMul       !ScratchIndex !FusionSource !FusionSource
    -- ^ @scratch[i] := a * b@.

  | OpSinkWrite !Int !FusionSource !SinkPolicy
    -- ^ Write or accumulate the source value into output bus
    -- (the 'Int' is the bus index). Sink writes do not produce a
    -- scratch result.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)


-- | An operand source for arithmetic and sink-write ops. Constants
-- and node-output reads may be embedded directly in arithmetic ops
-- without first being materialized into scratch.
data FusionSource
  = SrcConst   !Double
    -- ^ A literal value. Equivalent to inlining 'OpLoadConst' at
    -- the use site.
  | SrcInput   !NodeIndex !PortIndex
    -- ^ Read the named node's output port at the current sample.
    -- Same constraints as 'OpLoadInput'.
  | SrcControl !NodeIndex !ControlIndex
    -- ^ Read a control slot. Control reads are block-rate; the
    -- interpreter caches the read at block start.
  | SrcScratch !ScratchIndex
    -- ^ Read the named scratch slot. The slot must have been
    -- written by an earlier op in the same program.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)


-- | How an 'OpSinkWrite' interacts with the destination bus.
--
--   * 'SinkOverwrite' replaces the previous value at the current
--     sample (typical for a single-writer bus).
--   * 'SinkAccumulate' adds to the previous value, mirroring the
--     §4.E.2 writer-slot-keyed contribution path. v1 of the
--     executor only uses 'SinkOverwrite'; 'SinkAccumulate' is in
--     the data model so that adding multi-writer support later
--     does not change the ABI.
data SinkPolicy
  = SinkOverwrite
  | SinkAccumulate
  deriving stock    (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)


-- | An empty program. Useful as a starting point for builders /
-- tests; the loader rejects empty programs because they have no
-- effect on any bus.
emptyFusionProgram :: FusionProgram
emptyFusionProgram = FusionProgram
  { fpOps          = []
  , fpScratchSlots = 0
  }


-- | Count of ops in a program, in declaration order.
programOpCount :: FusionProgram -> Int
programOpCount = length . fpOps
