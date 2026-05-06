{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}

{- Note [Pipeline reading order]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Read the MetaSonic modules in pipeline order

  Types → Source → Validate → IR → Compile → FFI

MetaSonic.Types
  It defines every type name that appears in the other modules:
  NodeID, NodeIndex, Rate, Eff, NodeKind.

MetaSonic.Bridge.Source
  This is where graphs are written.

MetaSonic.Validate
  The gate between construction and compilation.

MetaSonic.Bridge.IR
  First compilation pass. This is where the source vocabulary (UGen, Connection)
  is stripped and replaced with the compiler's vocabulary (NodeIR, InputConn)
  plus semantic annotations (Rate, Eff). lowerGraph ties together validation,
  sorting, lowering, and rate checking in one function. This is the module where
  the argument about surface syntax vs semantic syntax becomes concrete.

MetaSonic.Bridge.Compile
  Read formRegions (region formation), then compileRuntimeGraph (the decisive
  NodeID → NodeIndex transformation). The Region and RegionGraph types are where
  scheduling logic lives. See Note [Region formation] and Note [Dense lowering]
  in MetaSonic.Compile.

MetaSonic.Bridge.FFI
  loadRuntimeGraph is the marshaling function that walks the
  dense RuntimeGraph and emits FFI calls. After reading this,
  you know exactly what crosses to C++ and in what form.


-}

-- |
-- Module      : MetaSonic.Types
-- Description : Shared vocabulary for the compilation pipeline
--
-- This module defines the types that every stage of the pipeline
-- shares.

module MetaSonic.Types
  ( -- * Symbolic identifiers (only during compilation)
    NodeID (..)
  , -- * Runtime identifiers
    NodeIndex (..)
  , PortIndex (..)
  , ControlIndex (..)
  , -- * Node classification
    NodeKind (..)
  , kindTag
  , -- * Per-kind metadata
    KindSpec (..)
  , kindSpec
  , -- * Rate discipline
    Rate (..)
  , -- * Resource effects
    Eff (..)
  ) where

import           Control.DeepSeq (NFData)
import           Foreign.C.Types (CInt)
import           GHC.Generics    (Generic)

{- Note [Shared vocabulary design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The types in this module reflect three principles:

1. Nominal identity matters.
   A NodeID is not a NodeIndex, even though both wrap Int.
   The Haskell type system enforces the distinction between
   symbolic identifiers (which exist only during compilation)
   and dense runtime positions (which survive into the C++
   runtime). Collapsing them would allow the kind of symbolic-
   runtime confusion that MetaSonic exists to prevent.

2. Semantic annotations are compilation artifacts.
   The Rate and Eff types exist because time and resource
   access are part of the compilation problem, not runtime
   concerns. Faust's semantic typing dimensions — signal
   nature, interval, computation time, speed,
   parallelizability — motivate a richer typed IR in which
   these distinctions become explicit. MetaSonic extends
   Faust's list with resource effects, which become essential
   for correct parallel scheduling.

3. The vocabulary is shared, but the flow is one-directional.
   Types defined here are imported by every module from Source
   through FFI, but information flows strictly forward through
   the pipeline. No downstream module writes back into an
   upstream representation. This is the module-level
   expression of the staged architecture.
-}

{- Note [Symbolic vs dense identifiers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
NodeID, NodeIndex, PortIndex, and ControlIndex are represented
as distinct newtypes, preserving nominal distinctions between
otherwise integer-like identifiers.

Symbolic identifiers (NodeID) exist on the Haskell side only.
A NodeID names a node in the source graph; it is meaningful
during construction, validation, and ordering. It does not
survive into the runtime.

The decisive transformation in the compiler
(compileRuntimeGraph in MetaSonic.Compile) replaces every
NodeID with a dense NodeIndex, after which symbolic identity
is erased. See Note [Dense lowering] in MetaSonic.Compile.

Dense identifiers (NodeIndex, PortIndex, ControlIndex) cross
the FFI boundary. On the C++ side, the same nominal
distinctions are maintained (NodeIndex, PortIndex,
ControlIndex are separate structs in rt_graph.cpp), ensuring
that the Haskell compiler and the C++ runtime agree on what
each integer means — by convention, not by a shared type
definition, but the convention is enforced by identical
newtype/struct discipline on both sides.
-}

-- | A symbolic node identifier, meaningful only during
-- compilation. After 'MetaSonic.Compile.compileRuntimeGraph',
-- no 'NodeID' survives into the runtime representation.
newtype NodeID = NodeID Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | A dense position in the runtime node array. Storage
-- order equals execution order; the runtime iterates
-- sequentially and never reorders.
newtype NodeIndex = NodeIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Identifies one output or input port on a node.
newtype PortIndex = PortIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Identifies one control slot on a node (e.g., frequency,
-- gain amount). Controls are set at graph load time and may
-- be overridden at block rate by incoming connections.
newtype ControlIndex = ControlIndex Int
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

-- | Note: tag 4 was reserved for a generic biquad family but is
-- intentionally unallocated. The Haskell→C++ contract test
-- (see Spec.hs) iterates [minBound..maxBound] via the derived
-- 'Enum'\/'Bounded' instances, so any new constructor added here
-- is automatically asserted against the C++ kind_from_tag dispatch.
data NodeKind
  = KSinOsc
  | KOut
  | KGain
  | KSawOsc
  | KNoiseGen
  | KLPF
  | KAdd
  | KEnv
  | KBusOut
  | KBusIn
  deriving stock    (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

{- Note [Per-kind metadata table]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
'KindSpec' centralises the *kind-level* facts about each 'NodeKind': ABI tag,
rate, audio/control arities, and label. Adding a new 'NodeKind' is one row
here plus a constructor in 'NodeKind', a constructor in 'UGen', a row in
'ugenView' (Source), and a builder.

The 'ksAudioArity' and 'ksControlArity' fields are cross-checked against
'ugenView' by a property test, so drift between the table and the constructor
shape is caught at test time rather than in the runtime.

Effects are deliberately *not* stored here. 'BusOut n' / 'BusIn n' carry a
bus number in a constructor field, so their 'Eff' annotation
('BusWrite n' / 'BusRead n') depends on per-instance data that the kind-level
table cannot represent. Putting '[Pure]' in a kind-level effects column for
those kinds would be a lie that defeats the scheduling pass — the whole
point of the 'Eff' machinery is that 'BusRead' / 'BusWrite' annotations
drive effect-induced edges in 'MetaSonic.Bridge.Validate'.

The corresponding per-UGen function 'MetaSonic.Bridge.IR.inferEff' is the
single source of truth for effects; it returns '[Pure]' for the kinds where
that is honest and overrides for the kinds whose effects depend on
constructor fields. See Note [Effect-induced edges (E_r)] in
"MetaSonic.Bridge.Validate" for how those annotations drive scheduling.

The same shape applies to 'inferRate': today every kind is 'SampleRate' so
'ksRate' is load-bearing, but when rate propagation lands (a 'Gain' fed by
'BlockRate' inputs becomes 'BlockRate'), 'ksRate' will become a
kind-level *minimum* and 'inferRate' will override per-instance.
-}

-- | Per-kind metadata. Indexed by 'NodeKind' via 'kindSpec'.
data KindSpec = KindSpec
  { ksTag          :: !CInt
    -- ^ ABI tag. Must match the C++ @kind_from_tag@ dispatch.
  , ksRate         :: !Rate
    -- ^ Kind-level rate (today every kind is 'SampleRate'; see
    -- Note [Rate inference vs rate propagation] in "MetaSonic.Bridge.IR").
  , ksAudioArity   :: !Int
    -- ^ Number of @Connection@ inputs the corresponding 'UGen' constructor
    -- carries.
  , ksControlArity :: !Int
    -- ^ Number of control slots the C++ kernel expects, in declared order.
    -- The mapping from inputs to controls is per-kind and is realised by
    -- 'MetaSonic.Bridge.Source.ugenView'; this field exists for cross-check
    -- only.
  , ksLabel        :: !String
    -- ^ Human-readable label used by source-level builders for 'nsName'.
  }

-- | Resolve per-kind metadata.
--
-- Note: tag 4 was reserved for a generic biquad family but is intentionally
-- unallocated. The Haskell→C++ contract test (see Spec.hs) iterates
-- @[minBound..maxBound]@ via the derived 'Enum'\/'Bounded' instances on
-- 'NodeKind', so any new constructor added here is automatically asserted
-- against the C++ @kind_from_tag@ dispatch.
kindSpec :: NodeKind -> KindSpec
kindSpec = \case
  KSinOsc   -> KindSpec 1  SampleRate 2 2 "sinOsc"
  KOut      -> KindSpec 2  SampleRate 1 1 "out"
  KGain     -> KindSpec 3  SampleRate 2 1 "gain"
  KSawOsc   -> KindSpec 5  SampleRate 2 2 "sawOsc"
  KNoiseGen -> KindSpec 6  SampleRate 0 0 "noiseGen"
  KLPF      -> KindSpec 7  SampleRate 3 2 "lpf"
  KAdd      -> KindSpec 8  SampleRate 2 2 "add"
  KEnv      -> KindSpec 9  SampleRate 1 5 "env"
  -- Bus routing: same-cycle BusOut/BusIn. Effects are per-instance
  -- (BusWrite n / BusRead n) and live in 'inferEff', not here. The C++
  -- runtime stores all buses in one pool (g.output_buses); the audio
  -- callback routes [0..N-1] to hardware regardless of which kind wrote
  -- them, so KOut and KBusOut are operationally identical and BusIn
  -- reads from the same pool.
  -- See Note [Effect-induced edges (E_r)] in MetaSonic.Bridge.Validate.
  KBusOut   -> KindSpec 10 SampleRate 1 1 "busOut"
  KBusIn    -> KindSpec 11 SampleRate 0 1 "busIn"

-- | Must agree with the NodeKind enum and kind_from_tag dispatch in
-- rt_graph.cpp. Verified by a contract test in Spec.hs.
kindTag :: NodeKind -> CInt
kindTag = ksTag . kindSpec

{- Note [Rate discipline]
~~~~~~~~~~~~~~~~~~~~~~~~~
A signal is not merely a stream of numbers. It has a staging
discipline, a rate discipline, and potentially resource effects
and synchronization constraints.

For comparison:
Faust's compiler distinguishes five semantic typing dimensions:
signal nature, interval of values, computation time, speed
(constant, block/UI-rate, or sample-rate), and
parallelizability.

MetaSonic adopts the speed dimension and uses it directly as the Rate type.

The ordering is significant:

  CompileRate < InitRate < BlockRate < SampleRate

A higher-rate node may freely read from a lower-rate node (the
value is simply held constant over the faster time scale —
sample-and-hold). A lower-rate node reading from a higher-rate
node requires explicit downsampling; this is a compilation
error unless a conversion node is inserted.

Rate annotations influence three downstream passes:

  1. Validation — checkRateEdges in MetaSonic.IR rejects edges
     where a lower-rate node reads from a higher-rate node
     without explicit conversion.

  2. Region formation — nodes must share a compatible rate to
     belong to the same region.
     See Note [Region rate compatibility] in MetaSonic.Compile.

  3. Future vectorization — sample-rate regions are candidates
     for SIMD; block-rate regions are not.

Currently, rates are inferred by dispatch on NodeKind alone
(inferRate in MetaSonic.IR). A future improvement would
propagate rates upward from inputs so that, for example, a
Gain fed by two BlockRate signals is itself BlockRate.

See Note [Rate inference vs rate propagation] in MetaSonic.IR.
-}

-- | The rate at which a signal is computed.
--
-- See Note [Rate discipline].
data Rate
  = CompileRate   -- ^ Known at compile time (literal constants)
  | InitRate      -- ^ Computed once at graph initialization
  | BlockRate     -- ^ Recomputed once per audio block
  | SampleRate    -- ^ Recomputed every sample
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

{- Note [Resource effects]
~~~~~~~~~~~~~~~~~~~~~~~~~~
A major lesson from SuperNova is that graph edges alone do not
determine correct parallel execution. If two subgraphs read
and write shared buses or buffers, the linearized order of a
sequential graph may induce a semantic dependency not visible
in the explicit graph structure.

Formally, if G = (N, E_s) is the structural graph, then the
semantically schedulable graph is:

  G* = (N, E_s ∪ E_r ∪ E_t)

where E_s are structural edges (explicit connections), E_r are
resource-induced edges, and E_t are temporal or rate-boundary
edges.

The Eff type captures the resource dimension:

  Pure      — no shared-resource interaction; can be freely
              reordered or parallelized (subject to data deps)
  BusRead   — reads from a shared bus; induces an ordering
              constraint with any BusWrite on the same bus
  BusWrite  — writes to a shared bus; induces ordering with
              both BusRead and other BusWrite on the same bus
  BufRead   — reads from a shared buffer
  BufWrite  — writes to a shared buffer
-}

-- | Resource effects carried by a node.
data Eff
  = Pure                -- ^ No shared-resource interaction
  | BusRead  !Int       -- ^ Reads from shared bus N
  | BusWrite !Int       -- ^ Writes to shared bus N
  | BufRead  !Int       -- ^ Reads from shared buffer N
  | BufWrite !Int       -- ^ Writes to shared buffer N
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)
