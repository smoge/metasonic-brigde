-- |
-- Module      : MetaSonic.Authoring
-- Description : Phase 8.A authoring DSL — first slice
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
--   * First routing/mix helpers ('mixN', constant equal-power
--     'pan2', and 'stereoOut') that remain transparent wrappers over
--     primitive Add/Gain/Out nodes.
--
-- Out of the current slice: 'balance' / 'spread' / 'send' /
-- 'returnBus' (Phase 8.D), ensemble builders that lower to
-- @[(String, SynthGraph)]@ (Phase 8.E), named-control authoring
-- objects (Phase 8.F), an inspector that surfaces authoring
-- metadata alongside the primitive graph (Phase 8.G).
--
-- The deliberate-lowering contract is pinned by tests in
-- @authoringDslTests@ (see @test/Spec.hs@): every public helper
-- here has at least one test asserting the primitive graph it
-- emits. Pretty-API behavior alone is not the contract; the
-- primitive shape is.
--
-- See [notes/2026-05-11-phase-8-authoring-dsl-design.md].

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

    -- * Outputs
  , outMono
  , outStereo
  , stereoOut
  , outChannels
  ) where

import           Control.Monad        (zipWithM)

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
outChannels bus (Channels cs) =
  mapM_ (\(i, c) -> out (bus + i) c) (zip [0 ..] cs)
