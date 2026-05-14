-- |
-- Module      : MetaSonic.Authoring
-- Description : Phase 8 authoring DSL — transparent composition helpers
--
-- The authoring layer elaborates down to ordinary 'SynthGraph' /
-- 'TemplateGraph' values. It is not a second compiler: every helper
-- here ultimately emits the same primitive @UGen@s and edges that
-- "MetaSonic.Bridge.Source" already provides, and validation / rate
-- inference / region formation / FFI loading still own correctness.
--
-- The authoring surface deliberately stays tiny and explicit:
--
--   * Three channel-collection types — 'Mono', 'Stereo', and
--     'Channels' — that wrap one, two, or many primitive
--     @Connection@s. They are authoring-time shapes only; the
--     runtime still sees mono buffers.
--
--   * Constructors and basic combinators ('mono', 'stereo',
--     'channels', 'duplicate', 'mapChannels', 'zipChannelsWith',
--     'sumChannels').
--
--   * Lifted gain / add / output helpers that expand channel-wise
--     to the existing primitive builders.
--
--   * Routing/mix helpers ('mixN', constant equal-power 'pan2',
--     static 'balance' / 'spread', explicit 'Bus' handles,
--     'send' / 'returnBus', and 'stereoOut') that remain
--     transparent wrappers over primitive Add/Gain/BusOut/BusIn/Out
--     nodes.
--
--   * An ensemble builder that lowers to the existing
--     @[(String, SynthGraph)]@ template input shape while adding
--     deterministic bus-name allocation and diagnostic-only
--     authoring metadata.
--
--   * Named controls that lower to tagged 'KSmooth' nodes and
--     optionally record MIDI CC bindings through the same Source-layer
--     path as 'cc'.
--
-- Out of the current slice: inspector metadata that surfaces
-- authoring constructs alongside the primitive graph (Phase 8.G).
--
-- The deliberate-lowering contract is pinned by tests in
-- @authoringDslTests@ (see @test/Spec.hs@): every public helper
-- here has at least one test asserting the primitive graph it
-- emits. Pretty-API behavior alone is not the contract; the
-- primitive shape is.
--
-- See [notes/2026-05-11-l-phase-8-authoring-dsl-design.md].

module MetaSonic.Authoring
  ( -- * Channel-collection types
    Mono (..)
  , Stereo (..)
  , Channels (..)

    -- * Constructors
  , mono
  , stereo
  , channels
  , duplicate

    -- * Channel combinators
  , monoConnection
  , stereoConnections
  , channelConnections
  , channelCount
  , mapChannels
  , zipChannelsWith
  , sumChannels
  , mixN
  , pan2

    -- * Lifted UGen primitives
  , gainM
  , gainS
  , gainC
  , addM
  , addS
  , addC
  , lpfM
  , lpfS
  , lpfC
  , hpfM
  , hpfS
  , hpfC
  , bpfM
  , bpfS
  , bpfC
  , notchM
  , notchS
  , notchC

    -- * Lifted stateful primitives (Phase 8.C2)
  , delayM
  , delayS
  , delayC
  , smoothM
  , smoothS
  , smoothC

    -- * Envelope application (Phase 8.C2)
  , envM
  , envS
  , envC

    -- * Routing helpers (Phase 8.D)
  , balance
  , spread
  , Bus (..)
  , bus
  , send
  , returnBus

    -- * Outputs
  , outMono
  , outStereo
  , stereoOut
  , outChannels

    -- * Named controls (Phase 8.F)
  , ControlName
  , unControlName
  , ControlRange
  , crMin
  , crMax
  , ControlOptions (..)
  , defaultControlOptions
  , NamedControlMetadata (..)
  , NamedControl (..)
  , controlName
  , controlRange
  , control
  , controlWith
  , ccControl
  , ccControlWith
  , controlMono
  , controlConnection

    -- * Ensemble builder (Phase 8.E)
  , AuthoredEnsemble (..)
  , EnsembleOptions (..)
  , defaultEnsembleOptions
  , TemplateRole (..)
  , AuthoringMetadata (..)
  , EnsembleM
  , ensemble
  , ensembleWith
  , busNamed
  , voice
  , fx
  ) where

import           Control.Monad        (ap, zipWithM)
import qualified Data.Map.Strict      as M
import           Data.Word            (Word8)

import           MetaSonic.Bridge.Source


------------------------------------------------------------
-- Channel-collection types
------------------------------------------------------------

-- | A single-channel audio shape. Wrapping an existing
-- 'Connection' adds no nodes: 'Mono' is a typed authoring handle
-- so helpers know how many channels they are looking at.
newtype Mono = Mono Connection
  deriving (Eq, Show)

-- | Two-channel audio shape. Lowers to two independent mono
-- paths; there is no stereo buffer at the runtime level.
data Stereo = Stereo
  { stereoLeft  :: !Connection
  , stereoRight :: !Connection
  } deriving (Eq, Show)

-- | N-channel audio shape backed by a list of mono connections.
-- The list-vs-NonEmpty choice is deliberate: empty 'Channels' is
-- a legal authoring value (e.g., a 'duplicate' n=0) and each
-- helper documents its behavior on the empty case rather than
-- requiring a runtime trap at construction.
newtype Channels = Channels { unChannels :: [Connection] }
  deriving (Eq, Show)

------------------------------------------------------------
-- Constructors
------------------------------------------------------------

-- | Wrap a 'Connection' as a single-channel audio shape.
mono :: Connection -> Mono
mono = Mono

-- | Build a stereo pair from two mono connections.
stereo :: Connection -> Connection -> Stereo
stereo = Stereo

-- | Build a multi-channel shape from a list of mono connections.
-- An empty list is allowed but most consumers will treat it as a
-- no-op.
channels :: [Connection] -> Channels
channels = Channels

-- | Replicate a mono channel N times. @duplicate 0 m@ produces an
-- empty 'Channels'; @duplicate 2 m@ produces the two-element list
-- a 'Stereo' counterpart would use.
duplicate :: Int -> Mono -> Channels
duplicate n (Mono c) = Channels (replicate (max 0 n) c)

------------------------------------------------------------
-- Channel introspection
------------------------------------------------------------

monoConnection :: Mono -> Connection
monoConnection (Mono c) = c

stereoConnections :: Stereo -> (Connection, Connection)
stereoConnections (Stereo l r) = (l, r)

channelConnections :: Channels -> [Connection]
channelConnections (Channels cs) = cs

channelCount :: Channels -> Int
channelCount (Channels cs) = length cs

------------------------------------------------------------
-- Channel combinators
------------------------------------------------------------

-- | Apply a 'SynthM' action to each channel independently. The
-- generated nodes are emitted in channel order, left to right —
-- callers can rely on that for migration-key stability.
mapChannels :: (Connection -> SynthM Connection)
            -> Channels -> SynthM Channels
mapChannels f (Channels cs) = Channels <$> mapM f cs

-- | Zip two channel collections with a binary 'SynthM' action.
-- Mismatched channel counts are an error — callers must broadcast
-- explicitly via 'duplicate' or 'channels' rather than relying on
-- implicit replication. (See §7.2 of the design note: silent
-- broadcasting can hide mistakes.) 'SynthM' is currently a pure
-- 'State' builder without a validation/error channel, so this stays
-- an immediate authoring-time failure until Phase 8 grows a proper
-- diagnostic surface.
zipChannelsWith
  :: (Connection -> Connection -> SynthM Connection)
  -> Channels -> Channels -> SynthM Channels
zipChannelsWith f (Channels xs) (Channels ys)
  | length xs == length ys = Channels <$> zipWithM f xs ys
  | otherwise = error $
      "zipChannelsWith: channel count mismatch ("
      <> show (length xs) <> " vs " <> show (length ys) <> ")"

-- | Sum a multi-channel shape into a single mono channel. The
-- summation is a left fold of 'add' calls, emitting (N-1) Add
-- nodes for N channels. Empty 'Channels' lowers to the literal
-- constant 0.0 ('Param 0.0'), not an allocated audio-producing
-- node. It can still feed lifted helpers because primitive inputs
-- accept ordinary 'Connection' values.
sumChannels :: Channels -> SynthM Mono
sumChannels (Channels []) = pure (Mono (Param 0.0))
sumChannels (Channels (c0 : rest)) = do
  let go acc x = add acc x
  total <- foldM' go c0 rest
  pure (Mono total)

-- | Mix a list of mono signals down to one mono signal. Empty input
-- follows 'sumChannels': it lowers to literal 0.0 and emits no Add
-- node.
mixN :: [Mono] -> SynthM Mono
mixN monos =
  sumChannels (Channels (map monoConnection monos))

-- | Constant equal-power pan from mono to stereo. @pan = -1@ is hard
-- left, @0@ is center, and @1@ is hard right. Values outside the
-- range are clamped. This helper emits two ordinary Gain nodes.
pan2 :: Mono -> Double -> SynthM Stereo
pan2 (Mono c) pan = do
  let p = clamp (-1.0) 1.0 pan
      l = sqrt (0.5 * (1.0 - p))
      r = sqrt (0.5 * (1.0 + p))
  Stereo <$> gain c (Param l) <*> gain c (Param r)

-- | Strict left fold in 'SynthM' — local helper, intentionally
-- not exported.
foldM' :: Monad m => (a -> b -> m a) -> a -> [b] -> m a
foldM' _ z []       = pure z
foldM' f z (x : xs) = do
  z' <- f z x
  foldM' f z' xs

clamp :: Ord a => a -> a -> a -> a
clamp lo hi = max lo . min hi

------------------------------------------------------------
-- Lifted UGen primitives
------------------------------------------------------------
--
-- These mirror the primitive 'gain' / 'add' / 'lpf' / 'out'
-- builders. The lifted versions exist so multichannel patches
-- don't repeat per-channel boilerplate; each one emits exactly
-- the same primitive nodes the user would write by hand.

gainM :: Mono -> Connection -> SynthM Mono
gainM (Mono c) amount = Mono <$> gain c amount

gainS :: Stereo -> Connection -> SynthM Stereo
gainS (Stereo l r) amount =
  Stereo <$> gain l amount <*> gain r amount

gainC :: Channels -> Connection -> SynthM Channels
gainC (Channels cs) amount =
  Channels <$> mapM (`gain` amount) cs

addM :: Mono -> Mono -> SynthM Mono
addM (Mono a) (Mono b) = Mono <$> add a b

addS :: Stereo -> Stereo -> SynthM Stereo
addS (Stereo al ar) (Stereo bl br) =
  Stereo <$> add al bl <*> add ar br

addC :: Channels -> Channels -> SynthM Channels
addC = zipChannelsWith add

lpfM :: Mono -> Connection -> Connection -> SynthM Mono
lpfM (Mono c) cutoff q = Mono <$> lpf c cutoff q

lpfS :: Stereo -> Connection -> Connection -> SynthM Stereo
lpfS (Stereo l r) cutoff q =
  Stereo <$> lpf l cutoff q <*> lpf r cutoff q

lpfC :: Channels -> Connection -> Connection -> SynthM Channels
lpfC (Channels cs) cutoff q =
  Channels <$> mapM (\c -> lpf c cutoff q) cs

-- High-pass biquads. Mirrors 'lpfM' / 'lpfS' / 'lpfC' exactly:
-- one 'KHPF' per channel, no filter state shared across
-- channels. Stereo HPF emits two independent filters; channel-
-- wise HPF emits one per slot.

hpfM :: Mono -> Connection -> Connection -> SynthM Mono
hpfM (Mono c) cutoff q = Mono <$> hpf c cutoff q

hpfS :: Stereo -> Connection -> Connection -> SynthM Stereo
hpfS (Stereo l r) cutoff q =
  Stereo <$> hpf l cutoff q <*> hpf r cutoff q

hpfC :: Channels -> Connection -> Connection -> SynthM Channels
hpfC (Channels cs) cutoff q =
  Channels <$> mapM (\c -> hpf c cutoff q) cs

-- Band-pass biquads. Same shape as the LPF / HPF families.

bpfM :: Mono -> Connection -> Connection -> SynthM Mono
bpfM (Mono c) cutoff q = Mono <$> bpf c cutoff q

bpfS :: Stereo -> Connection -> Connection -> SynthM Stereo
bpfS (Stereo l r) cutoff q =
  Stereo <$> bpf l cutoff q <*> bpf r cutoff q

bpfC :: Channels -> Connection -> Connection -> SynthM Channels
bpfC (Channels cs) cutoff q =
  Channels <$> mapM (\c -> bpf c cutoff q) cs

-- Notch biquads. Same shape as the LPF / HPF / BPF families.

notchM :: Mono -> Connection -> Connection -> SynthM Mono
notchM (Mono c) cutoff q = Mono <$> notch c cutoff q

notchS :: Stereo -> Connection -> Connection -> SynthM Stereo
notchS (Stereo l r) cutoff q =
  Stereo <$> notch l cutoff q <*> notch r cutoff q

notchC :: Channels -> Connection -> Connection -> SynthM Channels
notchC (Channels cs) cutoff q =
  Channels <$> mapM (\c -> notch c cutoff q) cs

------------------------------------------------------------
-- Lifted stateful primitives (Phase 8.C2)
------------------------------------------------------------
--
-- These wrap 'delayL' and 'smooth'. Each preserves primitive
-- visibility — the lowered graph still shows one 'KDelay' or
-- 'KSmooth' per channel. The runtime allocates per-instance
-- state per node, so sharing the helper across multiple
-- channels would silently collapse the multi-channel image
-- (every channel would carry the same delay history). The
-- multichannel lifts therefore emit one node per channel,
-- exactly as a hand-authored patch would.

-- | Mono fractional delay line. The first argument is the
-- compile-time maximum delay in seconds (sizes the per-instance
-- ring buffer); the third is the runtime delay time, which may
-- be an audio-rate 'Connection' or a constant 'Param'.
delayM :: Double -> Mono -> Connection -> SynthM Mono
delayM maxT (Mono c) time = Mono <$> delayL maxT c time

-- | Stereo delay. Emits two independent 'KDelay' nodes, both
-- sized to the same compile-time maximum. The delay time
-- input is shared across channels — pan-style varying delays
-- still need per-channel time inputs and should call 'delayM'
-- per channel.
delayS :: Double -> Stereo -> Connection -> SynthM Stereo
delayS maxT (Stereo l r) time =
  Stereo <$> delayL maxT l time <*> delayL maxT r time

-- | Channel-wise delay. Empty 'Channels' emits no nodes.
delayC :: Double -> Channels -> Connection -> SynthM Channels
delayC maxT (Channels cs) time =
  Channels <$> mapM (\c -> delayL maxT c time) cs

-- | Mono dynamic-smoother. The first argument is the
-- compile-time smoothing frequency in Hz (smaller = laggier).
-- See the 'smooth' primitive's haddock for the safe-range
-- discussion.
smoothM :: Double -> Mono -> SynthM Mono
smoothM baseHz (Mono c) = Mono <$> smooth baseHz c

-- | Stereo smoother. Two independent 'KSmooth' nodes; the
-- inputs are the stereo pair's two channels.
smoothS :: Double -> Stereo -> SynthM Stereo
smoothS baseHz (Stereo l r) =
  Stereo <$> smooth baseHz l <*> smooth baseHz r

-- | Channel-wise smoother. Empty 'Channels' emits no nodes.
smoothC :: Double -> Channels -> SynthM Channels
smoothC baseHz (Channels cs) =
  Channels <$> mapM (smooth baseHz) cs

------------------------------------------------------------
-- Envelope application (Phase 8.C2)
------------------------------------------------------------
--
-- 'envM' / 'envS' / 'envC' apply an envelope to a signal
-- shape rather than just re-exporting the 'env' primitive
-- builder. The multichannel variants share a single 'KEnv'
-- node across all channels: one coherent amplitude
-- trajectory drives N parallel 'KGain' multiplies, instead of
-- N independent envelopes that could drift if the gate inputs
-- ever differed. If the author wants per-channel envelope
-- state, the documented path is calling 'envM' per channel.
--
-- Empty 'Channels' policy: 'envC (Channels [])' emits **zero**
-- nodes — no dead 'KEnv'. The semantics of "apply an envelope
-- to nothing" is "nothing happens." This matches 'gainC' /
-- 'lpfC' / 'mapChannels' behavior on empty input.

-- | Apply an ADSR envelope to a mono signal. Emits one 'KEnv'
-- and one 'KGain' node; the gain's amount is the envelope
-- output and its signal input is the source.
envM
  :: Mono       -- ^ signal to envelope
  -> Connection -- ^ gate
  -> Connection -- ^ attack (s)
  -> Connection -- ^ decay (s)
  -> Connection -- ^ sustain (linear 0..1)
  -> Connection -- ^ release (s)
  -> SynthM Mono
envM (Mono c) gate a d s r = do
  e <- env gate a d s r
  Mono <$> gain c e

-- | Apply a single shared ADSR envelope to a stereo signal.
-- Emits exactly one 'KEnv' plus two 'KGain' nodes; both
-- 'KGain's read from the same 'KEnv' output, keeping the
-- stereo image coherent under amplitude modulation.
envS
  :: Stereo
  -> Connection -- ^ gate
  -> Connection -- ^ attack (s)
  -> Connection -- ^ decay (s)
  -> Connection -- ^ sustain (linear 0..1)
  -> Connection -- ^ release (s)
  -> SynthM Stereo
envS (Stereo l r) gate a d s rel = do
  e <- env gate a d s rel
  Stereo <$> gain l e <*> gain r e

-- | Apply a single shared ADSR envelope to a multichannel
-- signal. Emits one 'KEnv' plus N 'KGain' nodes; every
-- 'KGain' reads from the same 'KEnv'. Empty 'Channels' emits
-- zero nodes, no dead envelope.
envC
  :: Channels
  -> Connection -- ^ gate
  -> Connection -- ^ attack (s)
  -> Connection -- ^ decay (s)
  -> Connection -- ^ sustain (linear 0..1)
  -> Connection -- ^ release (s)
  -> SynthM Channels
envC (Channels []) _ _ _ _ _ = pure (Channels [])
envC (Channels cs) gate a d s r = do
  e <- env gate a d s r
  Channels <$> mapM (`gain` e) cs

------------------------------------------------------------
-- Routing helpers (Phase 8.D)
------------------------------------------------------------
--
-- 'balance' and 'spread' are *static* helpers: their pan
-- arguments are 'Double's read at graph-build time and lower
-- to constant 'Gain' amounts. The current primitive set
-- cannot honestly express audio-rate equal-power pan (no
-- sqrt opcode the gain family understands at audio rate),
-- so 8.D deliberately stops at compile-time balance. A
-- future slice can revisit if a sqrt control-rate path
-- lands.
--
-- 'Bus' / 'send' / 'returnBus' wrap the existing 'busOut' /
-- 'busIn' primitives without adding any allocation policy.
-- Bus indices remain user-managed in 8.D; deterministic
-- allocation belongs to 8.E ensemble builders where
-- template names and roles exist to drive it.

-- | Static balance for a stereo signal. @balance s p@ where
-- @p ∈ [-1, 1]@: negative values attenuate the right
-- channel and leave the left at unity; positive values
-- attenuate the left and leave the right at unity. @p = 0@
-- is the identity (both gains are 1.0). Values outside
-- the range are clamped.
--
-- Emits exactly two 'KGain' nodes (one per channel).
balance :: Stereo -> Double -> SynthM Stereo
balance (Stereo l r) p = do
  let pc = clamp (-1.0) 1.0 p
      gL = if pc <= 0 then 1.0          else 1.0 - pc
      gR = if pc <= 0 then 1.0 + pc     else 1.0
  Stereo <$> gain l (Param gL) <*> gain r (Param gR)

-- | Static spread: pan @N@ mono sources across the stereo
-- field. @spread monos width@ where @width ∈ [0, 1]@
-- scales the per-source pan positions; @width = 1@ is full
-- spread (-1 to +1), @width = 0@ collapses every source to
-- center (pan2 0.0), and intermediate values scale
-- linearly. Negative widths are clamped to 0.
--
-- The per-source pan positions for @N@ sources are
-- @-width, -width + 2*width/(N-1), …, +width@ for @N ≥ 2@.
-- @N = 1@ uses pan2 with width = 0 (centered). @N = 0@
-- returns silence on both channels and emits no nodes.
--
-- Concrete shape pins:
--   * @spread [] _@                 → 0 'KGain' / 0 'KAdd'
--   * @spread [m] _@                → 2 'KGain' / 0 'KAdd'
--   * @spread [m_1..m_N] _@ (N ≥ 2) → 2N 'KGain' / 2(N-1) 'KAdd'
spread :: [Mono] -> Double -> SynthM Stereo
spread []  _ = pure (Stereo (Param 0.0) (Param 0.0))
spread [m] _ = pan2 m 0.0
spread monos width = do
  let n  = length monos
      w  = clamp 0.0 1.0 width
      step
        | n <= 1    = 0.0
        | otherwise = (2 * w) / fromIntegral (n - 1)
      positions = [ -w + step * fromIntegral i
                  | i <- [0 .. n - 1]
                  ]
  panned <- zipWithM pan2 monos positions
  let lefts  = [ l | Stereo l _ <- panned ]
      rights = [ r | Stereo _ r <- panned ]
  l <- foldM' add (head lefts)  (tail lefts)
  r <- foldM' add (head rights) (tail rights)
  pure (Stereo l r)

-- | Authoring-level bus handle. Wraps an 'Int' bus index.
-- The wrapping exists for call-site clarity: a 'Bus' value
-- is what 'send' writes to and 'returnBus' reads from, and
-- the bus index stays visible in every signature.
newtype Bus = Bus { unBus :: Int }
  deriving (Eq, Ord, Show)

-- | Smart constructor for a 'Bus' value. Equivalent to the
-- 'Bus' constructor; provided so call sites can read as
-- @Auth.bus 7@ rather than @Bus 7@.
bus :: Int -> Bus
bus = Bus

-- | Write a mono signal to a shared audio bus. Lowers to a
-- single 'KBusOut' node on the named bus, exactly like the
-- primitive 'busOut'. Carries the same 'BusWrite' effect,
-- so 'compileTemplateGraph' picks it up in the template's
-- 'tplFootprint' without any new metadata.
send :: Bus -> Mono -> SynthM ()
send (Bus n) (Mono c) = busOut n c

-- | Read a shared audio bus into a 'Mono' authoring shape.
-- Lowers to a single 'KBusIn' node, exactly like the
-- primitive 'busIn'. Carries the 'BusRead' effect that
-- forces same-bus writers to precede this template at
-- 'compileTemplateGraph' time.
returnBus :: Bus -> SynthM Mono
returnBus (Bus n) = Mono <$> busIn n

------------------------------------------------------------
-- Outputs
------------------------------------------------------------

-- | Mono output on a single bus.
outMono :: Int -> Mono -> SynthM ()
outMono bus (Mono c) = out bus c

-- | Stereo output: left lands on @bus@, right on @bus + 1@.
-- This is the only place authoring-level shape implies bus
-- arithmetic; documenting it here keeps Phase 8's bus
-- visibility honest.
outStereo :: Int -> Stereo -> SynthM ()
outStereo bus (Stereo l r) = do
  out bus       l
  out (bus + 1) r

-- | Alias for 'outStereo' using the noun-first name from the Phase
-- 8.D routing plan.
stereoOut :: Int -> Stereo -> SynthM ()
stereoOut = outStereo

-- | Multi-channel output: channel @i@ lands on @bus + i@. Emits
-- one 'Out' node per channel in left-to-right order.
outChannels :: Int -> Channels -> SynthM ()
outChannels bus_ (Channels cs) =
  mapM_ (\(i, c) -> out (bus_ + i) c) (zip [0 ..] cs)

------------------------------------------------------------
-- Named controls (Phase 8.F)
------------------------------------------------------------
--
-- A named control is a tagged smoother node. The authoring
-- layer adds a name + default + range; the lowered graph is
-- the same @tagged name (smooth hz (Param default))@ pattern
-- callers already write by hand. MIDI CC binding is recorded
-- through the existing 'recordCCBinding' helper; OSC
-- resolution reuses the existing dispatcher grammar by
-- targeting the smoother's control slot 1.
--
-- The smoother's target slot is @1@ — the same slot 'cc'
-- targets. The dispatcher's '/<voice>/<node-tag>/<slot>'
-- grammar resolves to that slot through the migration key
-- the smoother carries.

-- | A validated control name. Constructed via 'controlName',
-- which checks the same identifier profile the OSC dispatcher
-- enforces (ASCII letters, digits, underscore, or hyphen;
-- non-empty; ≤16 UTF-8 bytes).
newtype ControlName = ControlName { unControlName :: String }
  deriving (Eq, Ord, Show)

-- | A validated value range. Constructed via 'controlRange',
-- which rejects @crMin >= crMax@.
--
-- Range is metadata plus MIDI CC scaling input. It is not
-- enforced at OSC runtime: an OSC write outside the declared
-- range still reaches the smoother target slot. Clamping is a
-- separate concern from authoring shape.
data ControlRange = ControlRange
  { crMin :: !Double
  , crMax :: !Double
  } deriving (Eq, Show)

-- | Options that parameterize a named-control build. Currently
-- just the smoother frequency; future slices can add fields
-- without breaking callers that use 'defaultControlOptions'.
data ControlOptions = ControlOptions
  { coSmoothingHz :: !Double
    -- ^ Smoother frequency for the underlying 'smooth' node.
    -- Default 20 Hz, matching 'cc'.
  } deriving (Eq, Show)

-- | Default options. 20 Hz matches the existing 'cc' smoother.
-- The exact value is pinned by tests; what matters is
-- agreement with 'cc' so a mixed CC + named-control patch has
-- one smoothing time constant.
defaultControlOptions :: ControlOptions
defaultControlOptions = ControlOptions { coSmoothingHz = 20.0 }

-- | Diagnostic-only metadata recorded alongside a 'NamedControl'.
-- The compile pipeline never sees this; it is for future
-- inspector / survey surfacing (Phase 8.G).
data NamedControlMetadata = NamedControlMetadata
  { ncmName        :: !String
  , ncmDefault     :: !Double
  , ncmRange       :: !ControlRange
  , ncmSmoothingHz :: !Double
  , ncmCC          :: !(Maybe Word8)
    -- ^ MIDI CC number, if the control was built via 'ccControl' /
    -- 'ccControlWith'; 'Nothing' for plain OSC-only controls.
  , ncmKey         :: !MigrationKey
    -- ^ The migration key stamped on the smoother node — the
    -- same bytes the OSC dispatcher matches against.
  , ncmSlot        :: !Int
    -- ^ Pinned to @1@: the smoother's target slot.
  } deriving (Eq, Show)

-- | An authored named control. 'ncMono' is the same mono
-- authoring shape every other helper returns; downstream
-- consumers compose against it without any new combinators.
-- 'ncMetadata' is diagnostic-only.
data NamedControl = NamedControl
  { ncMono     :: !Mono
  , ncMetadata :: !NamedControlMetadata
  } deriving (Eq, Show)

-- | Validate an OSC-safe identifier and wrap it as a
-- 'ControlName'. Mirrors the dispatcher's
-- 'isOscSafeIdentifier' rule: non-empty, at most 16 ASCII
-- bytes, made up of letters, digits, underscore, or hyphen.
-- Rejection happens at authoring time so an invalid name
-- never reaches the dispatcher in the first place.
controlName :: String -> Either String ControlName
controlName s
  | null s =
      Left "controlName: empty name"
  | length s > 16 =
      Left $ "controlName: name '" <> s
          <> "' is longer than 16 bytes"
  | not (all isOscChar s) =
      Left $ "controlName: name '" <> s
          <> "' contains characters outside [A-Za-z0-9_-]"
  | otherwise =
      Right (ControlName s)
  where
    isOscChar c =
         (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c == '_' || c == '-'

-- | Validate a @[min, max]@ range. Rejects non-finite values and
-- @min >= max@: a zero-width range has no meaningful MIDI scaling,
-- and the OSC layer does not clamp at runtime, so an inverted range
-- would silently produce surprising behavior.
controlRange :: Double -> Double -> Either String ControlRange
controlRange mn mx
  | not (finite mn) || not (finite mx) =
      Left $ "controlRange: bounds must be finite (min="
          <> show mn <> ", max=" <> show mx <> ")"
  | mn >= mx =
      Left $ "controlRange: min ("
          <> show mn
          <> ") must be strictly less than max ("
          <> show mx
          <> ")"
  | otherwise =
      Right ControlRange { crMin = mn, crMax = mx }
  where
    finite x = not (isNaN x || isInfinite x)

-- | Author a named, smoothed control under
-- 'defaultControlOptions'. Emits exactly one tagged 'KSmooth'
-- node carrying the control's name as its 'MigrationKey'. The
-- returned 'NamedControl' wraps the smoother's audio output
-- as a 'Mono', plus diagnostic metadata.
control
  :: ControlName
  -> Double         -- ^ initial \/ default target value
  -> ControlRange
  -> SynthM NamedControl
control = controlWith defaultControlOptions

-- | 'control' with explicit options. Use when a control needs
-- a non-default smoothing time constant.
controlWith
  :: ControlOptions
  -> ControlName
  -> Double
  -> ControlRange
  -> SynthM NamedControl
controlWith opts (ControlName name) defaultVal range = do
  conn <- tagged name
            (smooth (coSmoothingHz opts) (Param defaultVal))
  pure NamedControl
    { ncMono     = Mono conn
    , ncMetadata = NamedControlMetadata
        { ncmName        = name
        , ncmDefault     = defaultVal
        , ncmRange       = range
        , ncmSmoothingHz = coSmoothingHz opts
        , ncmCC          = Nothing
        , ncmKey         = MigrationKey name
        , ncmSlot        = 1
        }
    }

-- | Author a named, smoothed control that is also bound to a
-- MIDI CC number. The lowered shape is the same single tagged
-- 'KSmooth' as 'control'; the only difference is that the
-- builder records a 'CCSpec' targeting the smoother's slot 1
-- with the supplied range. The live-MIDI runner picks this up
-- through the existing 'runSynthCCs' path.
ccControl
  :: Word8
  -> ControlName
  -> Double
  -> ControlRange
  -> SynthM NamedControl
ccControl = ccControlWith defaultControlOptions

-- | 'ccControl' with explicit options.
ccControlWith
  :: ControlOptions
  -> Word8
  -> ControlName
  -> Double
  -> ControlRange
  -> SynthM NamedControl
ccControlWith opts ccNum cname defaultVal range = do
  nc <- controlWith opts cname defaultVal range
  case connectionNodeID (monoConnection (ncMono nc)) of
    Nothing ->
      error $ "ccControlWith: smoother for '"
           <> unControlName cname
           <> "' did not produce an audio node"
    Just nid -> do
      recordCCBinding CCSpec
        { ccsNumber = ccNum
        , ccsNode   = nid
        , ccsCtl    = 1
        , ccsMin    = crMin range
        , ccsMax    = crMax range
        }
      pure nc
        { ncMetadata = (ncMetadata nc) { ncmCC = Just ccNum } }

-- | Project a 'NamedControl' to its 'Mono' shape. Use when a
-- downstream helper expects 'Mono' directly.
controlMono :: NamedControl -> Mono
controlMono = ncMono

-- | Project a 'NamedControl' to the underlying 'Connection'.
-- Use when wiring into a primitive builder that takes
-- 'Connection' directly (e.g., 'lpf', 'gain').
controlConnection :: NamedControl -> Connection
controlConnection = monoConnection . ncMono

------------------------------------------------------------
-- Ensemble builder (Phase 8.E)
------------------------------------------------------------
--
-- The ensemble builder is a thin authoring monad that produces
-- an ordered '[(String, SynthGraph)]' plus deterministic bus
-- assignments. The output is exactly the shape
-- 'compileTemplateGraph' already consumes, so 'aeTemplates' can
-- be passed straight through. The metadata side
-- ('aeMetadata') is diagnostic only — 'compileTemplateGraph'
-- never sees it.
--
-- The builder is *not* a second compiler: it composes
-- pre-built 'SynthGraph' values built via the existing
-- 'runSynth'. Errors at the ensemble level (duplicate
-- template names, etc.) are surfaced via the 'Either String'
-- on 'ensemble' / 'ensembleWith', not threaded through
-- 'SynthM'.

-- | One authored ensemble: the declaration-order template list
-- plus the diagnostic-only metadata the builder collected.
-- 'aeTemplates' is what feeds 'compileTemplateGraph'.
data AuthoredEnsemble = AuthoredEnsemble
  { aeTemplates :: ![(String, SynthGraph)]
  , aeMetadata  :: !AuthoringMetadata
  } deriving (Eq, Show)

-- | Options that parameterize an ensemble build. Currently just
-- the bus base; future slices can add fields without breaking
-- callers that use 'defaultEnsembleOptions'.
data EnsembleOptions = EnsembleOptions
  { eoBusBase :: !Int
    -- ^ First bus index 'busNamed' allocates. Tests pin the
    -- default ('eoBusBase = 16').
  } deriving (Eq, Show)

-- | Default options. Bus base is @16@: above the common
-- 0-15 hardware/explicit-bus range typical patches use, so an
-- authored ensemble does not collide with a hand-managed bus
-- assignment by accident. The exact value is pinned by a
-- snapshot test; the stability of the choice is what matters,
-- not the specific number.
defaultEnsembleOptions :: EnsembleOptions
defaultEnsembleOptions = EnsembleOptions { eoBusBase = 16 }

-- | Per-template role tag, recorded for diagnostic use only.
-- The compile pipeline does not see this.
data TemplateRole = VoiceTemplate | FxTemplate
  deriving (Eq, Show)

-- | Diagnostic-only metadata. Lives on 'AuthoredEnsemble' and
-- carries the per-template role tags and the bus-name
-- assignment table. 'compileTemplateGraph' never reads this.
data AuthoringMetadata = AuthoringMetadata
  { amRoles :: ![(String, TemplateRole)]
    -- ^ Per-template role, in declaration order. Same length
    -- and order as 'aeTemplates'.
  , amBuses :: !(M.Map String Bus)
    -- ^ Bus name → 'Bus' assignment for every 'busNamed' call.
    -- Stable across 'ensemble' runs given the same builder
    -- input — see the determinism tests.
  } deriving (Eq, Show)

-- | Internal builder state. Hidden from the public surface.
data EnsembleState = EnsembleState
  { esTemplates :: ![(String, SynthGraph)]
    -- ^ Accumulated in *reverse* (prepended on add) so adds
    -- are O(1); reversed once at 'ensemble' time.
  , esRoles     :: ![(String, TemplateRole)]
    -- ^ Same reverse-accumulation rule.
  , esBuses     :: !(M.Map String Bus)
  , esNextBus   :: !Int
  }

initialState :: EnsembleOptions -> EnsembleState
initialState opts = EnsembleState
  { esTemplates = []
  , esRoles     = []
  , esBuses     = M.empty
  , esNextBus   = eoBusBase opts
  }

-- | The ensemble authoring monad. State + error. Deliberately
-- minimal — no IO, no reader, no parallelism. The 'Either
-- String' surface is where authoring-level errors land
-- ("duplicate template name", etc.). Users do not pattern
-- match on 'EnsembleM' directly; they compose 'busNamed' /
-- 'voice' / 'fx' inside a do-block and call 'ensemble' to run.
newtype EnsembleM a = EnsembleM
  { runEnsembleM :: EnsembleState
                 -> Either String (a, EnsembleState)
  }

instance Functor EnsembleM where
  fmap f (EnsembleM run) = EnsembleM $ \s ->
    case run s of
      Left err      -> Left err
      Right (a, s') -> Right (f a, s')

instance Applicative EnsembleM where
  pure a = EnsembleM $ \s -> Right (a, s)
  (<*>) = ap

instance Monad EnsembleM where
  return = pure
  EnsembleM run >>= k = EnsembleM $ \s ->
    case run s of
      Left err      -> Left err
      Right (a, s') -> runEnsembleM (k a) s'

-- | Build an 'AuthoredEnsemble' from a builder block under
-- 'defaultEnsembleOptions'. Authoring-level errors (duplicate
-- template names, etc.) come back as 'Left'; the right side is
-- always a fully-populated 'AuthoredEnsemble' whose
-- 'aeTemplates' can be passed straight to
-- 'compileTemplateGraph'.
ensemble :: EnsembleM () -> Either String AuthoredEnsemble
ensemble = ensembleWith defaultEnsembleOptions

-- | 'ensemble' with an explicit options record. Use this when
-- the default bus base would collide with a hand-managed
-- portion of the same patch, or when a future slice adds an
-- option this slice does not yet expose.
ensembleWith
  :: EnsembleOptions
  -> EnsembleM ()
  -> Either String AuthoredEnsemble
ensembleWith opts (EnsembleM run) = do
  (_, finalState) <- run (initialState opts)
  pure AuthoredEnsemble
    { aeTemplates = reverse (esTemplates finalState)
    , aeMetadata  = AuthoringMetadata
        { amRoles = reverse (esRoles finalState)
        , amBuses = esBuses finalState
        }
    }

-- | Allocate a 'Bus' under a stable name. Repeated calls with
-- the same name in the same ensemble return the same 'Bus'
-- without consuming a new index; the first call at name @n@
-- allocates the next free bus, starting from 'eoBusBase'.
--
-- Two ensembles built independently do *not* share bus
-- assignments — names are scoped to a single 'ensemble' run.
-- Federation across ensembles is a future slice's problem; this
-- one keeps the scope flat and the determinism local.
busNamed :: String -> EnsembleM Bus
busNamed name = EnsembleM $ \s ->
  case M.lookup name (esBuses s) of
    Just b  -> Right (b, s)
    Nothing ->
      let b   = Bus (esNextBus s)
          s'  = s { esBuses   = M.insert name b (esBuses s)
                  , esNextBus = esNextBus s + 1
                  }
      in Right (b, s')

-- | Internal: shared implementation for 'voice' / 'fx'.
addTemplate :: TemplateRole -> String -> SynthGraph -> EnsembleM ()
addTemplate role name g = EnsembleM $ \s ->
  if any ((== name) . fst) (esTemplates s)
    then Left $ "ensemble: duplicate template name '" <> name <> "'"
    else Right
      ( ()
      , s { esTemplates = (name, g) : esTemplates s
          , esRoles     = (name, role) : esRoles s
          }
      )

-- | Declare a voice template under the given name. Voice and
-- 'fx' differ only in the diagnostic role tag they record;
-- both append to 'aeTemplates' in declaration order. Duplicate
-- names at the ensemble level fail the whole build with
-- @Left "ensemble: duplicate template name '...'"@.
voice :: String -> SynthGraph -> EnsembleM ()
voice = addTemplate VoiceTemplate

-- | Declare an effect template under the given name. See
-- 'voice' for the contract.
fx :: String -> SynthGraph -> EnsembleM ()
fx = addTemplate FxTemplate
