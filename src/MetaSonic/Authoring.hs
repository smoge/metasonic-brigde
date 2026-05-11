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
-- Slice 1 deliberately keeps the surface tiny and explicit:
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
-- Out of slice 1: 'pan2' / 'balance' / 'mixN' / 'send' / 'returnBus'
-- (Phase 8.D), ensemble builders that lower to
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

    -- * Outputs
  , outMono
  , outStereo
  , outChannels
  ) where

import           Control.Monad        (zipWithM)

import           MetaSonic.Bridge.Source


------------------------------------------------------------
-- Channel-collection types
------------------------------------------------------------

-- | A single-channel audio shape. Wrapping an existing
-- 'Connection' adds no nodes: 'Mono' is purely a phantom-typed
-- handle so authoring helpers know how many channels they are
-- looking at.
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
-- broadcasting can hide mistakes.)
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
-- constant 0.0 — explicit so callers can decide whether to
-- forbid it upstream.
sumChannels :: Channels -> SynthM Mono
sumChannels (Channels []) = pure (Mono (Param 0.0))
sumChannels (Channels (c0 : rest)) = do
  let go acc x = add acc x
  total <- foldM' go c0 rest
  pure (Mono total)

-- | Strict left fold in 'SynthM' — local helper, intentionally
-- not exported.
foldM' :: Monad m => (a -> b -> m a) -> a -> [b] -> m a
foldM' _ z []       = pure z
foldM' f z (x : xs) = do
  z' <- f z x
  foldM' f z' xs

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

-- | Multi-channel output: channel @i@ lands on @bus + i@. Emits
-- one 'Out' node per channel in left-to-right order.
outChannels :: Int -> Channels -> SynthM ()
outChannels bus (Channels cs) =
  mapM_ (\(i, c) -> out (bus + i) c) (zip [0 ..] cs)
