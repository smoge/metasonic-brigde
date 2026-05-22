{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.Session.RTGraphAdapter
-- Description : Session-mode helpers for a caller-owned RTGraph.
--
-- This module starts the real-runtime side of Session Prep E without
-- creating a session owner, and now also hosts the Prep N/O supported
-- preserving hot-swap path. The functions here operate on a
-- caller-owned 'RTGraph' handle. The adapter constructor installs
-- graph metadata and returns a 'SessionRuntimeAdapter IO' for the
-- voice/control/install surface.
--
-- See [notes/2026-05-12-r-session-prep-e-rtgraph-adapter.md],
-- [notes/2026-05-13-f-session-prep-n-preserving-hot-swap-runtime-migration.md],
-- and [notes/2026-05-13-g-session-prep-o-live-audio-preserving-hot-swap.md].

module MetaSonic.Session.RTGraphAdapter
  ( -- * Options
    RTGraphAdapterOptions (..)
  , defaultRTGraphAdapterOptions

    -- * Install metadata
  , RTGraphAdapterState
  , rtgasGraph
  , rtgasTemplateIds
  , rtgasPrewarmCounts
  , rtgasAutoSpawnedSlots
  , rtgasRTGraph

    -- * Live hot-swap protocol
  , PreservingHotSwapExpectations (..)
  , LiveHotSwapProtocol (..)
  , runLiveHotSwapProtocol

    -- * Setup failures
  , SessionAdapterSetupIssue (..)
  , SessionPrewarmIssue (..)

    -- * Adapter
  , newRTGraphAdapter

    -- * Session-mode graph install
  , installSessionGraph
  ) where

import           Control.DeepSeq            (NFData)
import           Control.Applicative        ((<|>))
import           Control.Exception          (SomeException, displayException,
                                             try)
import           Control.Monad              (foldM, forM_, when)
import qualified Data.ByteString.Char8      as BSC
import           Data.Foldable              (traverse_)
import           Data.List                  (find)
import           Data.IORef                 (IORef, newIORef, readIORef,
                                             writeIORef)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (listToMaybe)
import qualified Data.Set                   as Set
import           Foreign.C.Types            (CDouble (..), CInt)
import           Foreign.Ptr                (Ptr, nullPtr)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.Compile   (RuntimeGraph (..),
                                             RuntimeNode (..))
import           MetaSonic.Bridge.FFI       (RTGraph, RTGraphSwap,
                                             SwapGeneration,
                                             SwapMigrationStats (..),
                                             TimeoutMs,
                                             collectRetiredSwapStats,
                                             c_rt_graph_audio_running,
                                             c_rt_graph_cancel_swap,
                                             c_rt_graph_capacity,
                                             c_rt_graph_collect_retired_swap,
                                             c_rt_graph_instance_remove,
                                             c_rt_graph_instance_set_control,
                                             c_rt_graph_max_frames,
                                             c_rt_graph_prepare_swap_from_graph,
                                             c_rt_graph_process,
                                             c_rt_graph_publish_swap,
                                             c_rt_graph_realtime_activate,
                                             c_rt_graph_realtime_cancel,
                                             c_rt_graph_realtime_release,
                                             c_rt_graph_realtime_reserve,
                                             c_rt_graph_realtime_set_control,
                                             c_rt_graph_swap_migration_lifecycle_copy_count,
                                             c_rt_graph_swap_migration_state_copy_count,
                                             c_rt_graph_template_instance_add,
                                             c_rt_graph_template_set_polyphony,
                                             readSwapGeneration,
                                             waitForSwapGeneration,
                                             loadTemplateGraphWithAutoSpawns,
                                             withRTGraph)
import           MetaSonic.Bridge.Templates (BufferFootprint (..),
                                             ResourceFootprint (..),
                                             Template (..), TemplateGraph (..))
import           MetaSonic.ControlTarget    (ControlTarget (..),
                                             resolveControlTarget)
import qualified MetaSonic.OSC.Dispatch     as OSC
import           MetaSonic.Pattern          (ControlTag, TemplateName (..),
                                             SwapLabel, Value, VoiceKey (..))
import           MetaSonic.Session.AdapterIssue
                                             (SessionAdapterSetupIssue (..),
                                             SessionPrewarmIssue (..))
import           MetaSonic.Session.Command  (HotSwapInstallMode (..))
import           MetaSonic.Session.Runtime  (SessionRuntimeAdapter (..),
                                             RealtimeOp (..),
                                             SessionRuntimeIssue (..),
                                             SessionRuntimeSuccess (..))
import           MetaSonic.Session.Resolve  (ResolveRebuildResult (..),
                                             VoiceBinding (..))
import           MetaSonic.Session.State    (SessionCommit (..),
                                             SessionPlan (..))
import           MetaSonic.Types            (NodeIndex (..), NodeKind (..))


-- | Construction-time sizing policy for session-mode graph install.
--
-- Per-template entries override 'raoDefaultPolyphony'. Values below
-- one are clamped to one to match the C ABI's polyphony policy.
data RTGraphAdapterOptions = RTGraphAdapterOptions
  { raoPerTemplatePolyphony :: !(Map.Map TemplateName Int)
  , raoDefaultPolyphony     :: !Int
  , raoHotSwapInstallTimeoutMs :: !Int
    -- ^ Timeout, in milliseconds, for a live-audio preserving
    -- hot-swap after publish succeeds. Negative waits indefinitely;
    -- zero performs one non-blocking generation check.
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

defaultRTGraphAdapterOptions :: RTGraphAdapterOptions
defaultRTGraphAdapterOptions = RTGraphAdapterOptions
  { raoPerTemplatePolyphony = Map.empty
  , raoDefaultPolyphony     = 1
  , raoHotSwapInstallTimeoutMs = 1000
  }

-- | Private runtime metadata produced by 'installSessionGraph'.
--
-- The constructor stays hidden so callers cannot fabricate metadata
-- that claims a graph was installed. The exposed readers are enough
-- for tests and for the adapter constructor that lands in the next
-- slice.
--
-- No 'NFData' instance: 'rtgasRTGraph' is a foreign pointer with no
-- useful normal form. Consumers must not rely on deep evaluation of
-- this metadata.
data RTGraphAdapterState = RTGraphAdapterState
  { rtgasGraph            :: !TemplateGraph
  , rtgasTemplateIds      :: !(Map.Map TemplateName Int)
  , rtgasPrewarmCounts    :: !(Map.Map TemplateName Int)
  , rtgasAutoSpawnedSlots :: !(Map.Map TemplateName Int)
  , rtgasRTGraph          :: !(Ptr RTGraph)
  } deriving stock (Eq, Show)

-- | Private mutable metadata captured by the IO adapter.
--
-- This is not a session owner. The pure 'SessionState' remains the
-- caller-visible source of truth; the IORef only tracks runtime
-- lookup metadata after constrained graph installs.
data RTGraphAdapterEnv = RTGraphAdapterEnv
  { rtaeState   :: !(IORef RTGraphAdapterState)
  , rtaeOptions :: !RTGraphAdapterOptions
  }

data PreservingHotSwapPlan = PreservingHotSwapPlan
  { phspBindings                :: ![VoiceBinding]
  , phspExpectedStateCopyCount  :: !Int
  }

-- | Verification thresholds for one preserving hot-swap install.
data PreservingHotSwapExpectations = PreservingHotSwapExpectations
  { phsePreservedBindingCount   :: !Int
  , phseExpectedStateCopyCount  :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Injectable live hot-swap install protocol.
--
-- The concrete RTGraph adapter wires these callbacks to the C runtime.
-- Tests can provide a deterministic fake to pin the producer-side
-- ordering without starting PortAudio.
data LiveHotSwapProtocol m swap = LiveHotSwapProtocol
  { lhpReadGeneration       :: m SwapGeneration
  , lhpAcquireSwap          :: m (Either SessionRuntimeIssue swap)
  , lhpPublishSwap          :: swap -> m (Either SessionRuntimeIssue ())
  , lhpWaitForGeneration    :: SwapGeneration -> TimeoutMs -> m Bool
  , lhpCollectRetiredStats  :: m (Maybe SwapMigrationStats)
  }

data PreservingBuilderMeta = PreservingBuilderMeta
  { pbmTemplateIds      :: !(Map.Map TemplateName Int)
  , pbmPrewarmCounts    :: !(Map.Map TemplateName Int)
  , pbmAutoSpawnedSlots :: !(Map.Map TemplateName Int)
  }

-- | Install a graph in session mode and return an adapter shell for
-- 'MetaSonic.Session.Step.stepSessionCommand'.
--
-- The returned adapter supports voice start, voice stop, control
-- writes, dropping/empty graph installs, and supported preserving
-- hot-swaps. It is still not a session owner and it still relies on
-- the caller to serialize producer calls per the realtime ABI's
-- single-producer contract.
newRTGraphAdapter
  :: Ptr RTGraph
  -> TemplateGraph
  -> RTGraphAdapterOptions
  -> IO (Either SessionAdapterSetupIssue (SessionRuntimeAdapter IO))
newRTGraphAdapter rt tg opts = do
  installed <- installSessionGraph rt tg opts
  case installed of
    Left issue ->
      pure (Left issue)
    Right st -> do
      ref <- newIORef st
      pure (Right (SessionRuntimeAdapter
        (runRTGraphAdapter RTGraphAdapterEnv
          { rtaeState   = ref
          , rtaeOptions = opts
          })))

-- | Install a 'TemplateGraph' in session mode.
--
-- The underlying loader still follows the existing stop/clear/rebuild
-- semantics. This helper then removes the loader-created auto-spawned
-- instances and prewarms the configured slot counts so later realtime
-- reserve calls can claim 'Available' slots without growing the pool.
--
-- On prewarm failure, slots already prewarmed for earlier templates
-- may remain in the pool. Recovery should retry 'installSessionGraph',
-- which goes through the loader's clear path, rather than attempting
-- partial runtime repair.
installSessionGraph
  :: Ptr RTGraph
  -> TemplateGraph
  -> RTGraphAdapterOptions
  -> IO (Either SessionAdapterSetupIssue RTGraphAdapterState)
installSessionGraph rt tg opts =
  case templateIdMap tg of
    Left duplicate ->
      pure (Left (SasiDuplicateTemplateName duplicate))
    Right ids -> do
      loaded <- try (loadTemplateGraphWithAutoSpawns rt tg)
      case loaded of
        Left err ->
          pure (Left (SasiLoaderException (displayException (err :: SomeException))))
        Right autoRows ->
          case autoSpawnRows tg autoRows of
            Left issue ->
              pure (Left issue)
            Right rows -> do
              forM_ rows $ \(_, _, slot) ->
                c_rt_graph_instance_remove rt (fromIntegral slot)
              prewarmed <- prewarmTemplates rt opts (tgTemplates tg)
              case prewarmed of
                Left issue ->
                  pure (Left issue)
                Right counts ->
                  pure (Right RTGraphAdapterState
                    { rtgasGraph            = tg
                    , rtgasTemplateIds      = ids
                    , rtgasPrewarmCounts    = counts
                    , rtgasAutoSpawnedSlots =
                        Map.fromList
                          [ (name, slot) | (name, _, slot) <- rows ]
                    , rtgasRTGraph          = rt
                    })

templateIdMap :: TemplateGraph -> Either TemplateName (Map.Map TemplateName Int)
templateIdMap tg =
  foldM step Map.empty (zip [0 ..] (tgTemplates tg))
  where
    step acc (tid, tpl)
      | Map.member name acc = Left name
      | otherwise           = Right (Map.insert name tid acc)
      where
        name = TemplateName (tplName tpl)

autoSpawnRows
  :: TemplateGraph
  -> [(Int, Int)]
  -> Either SessionAdapterSetupIssue [(TemplateName, Int, Int)]
autoSpawnRows tg rows =
  if actualCount /= expectedCount
     then Left (SasiAutoSpawnRowCountMismatch expectedCount actualCount)
     else go 0 templates rows
  where
    templates = tgTemplates tg
    expectedCount = length templates
    actualCount = length rows

    -- Assumes the loader assigns template ids
    -- [0 .. length tgTemplates - 1] in 'tgTemplates' order; this
    -- mismatch branch catches loader-protocol drift.
    go _ [] [] = Right []
    go expectedTid (tpl : tpls) ((tid, slot) : rest)
      | tid /= expectedTid =
          Left (SasiAutoSpawnTemplateIdMismatch expectedTid tid)
      | slot < 0 =
          Left (SasiAutoSpawnMissing name)
      | otherwise =
          ((name, tid, slot) :) <$> go (expectedTid + 1) tpls rest
      where
        name = TemplateName (tplName tpl)
    go _ _ _ =
      Left (SasiAutoSpawnRowCountMismatch expectedCount actualCount)

prewarmTemplates
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> [Template]
  -> IO (Either SessionAdapterSetupIssue (Map.Map TemplateName Int))
prewarmTemplates rt opts =
  foldM step (Right Map.empty) . zip ([0 ..] :: [Int])
  where
    step (Left issue) _ =
      pure (Left issue)
    step (Right acc) (tid, tpl) = do
      let name  = TemplateName (tplName tpl)
          count = configuredPrewarmCount opts tpl
          cTid  = fromIntegral tid
      c_rt_graph_template_set_polyphony rt cTid (fromIntegral count)
      result <- prewarmOne rt name cTid count
      pure $ case result of
        Left issue -> Left issue
        Right ()   -> Right (Map.insert name count acc)

prewarmOne
  :: Ptr RTGraph
  -> TemplateName
  -> CInt
  -> Int
  -> IO (Either SessionAdapterSetupIssue ())
prewarmOne rt name cTid count =
  go 1 []
  where
    go attempt slots
      | attempt > count = do
          forM_ slots (c_rt_graph_instance_remove rt)
          pure (Right ())
      | otherwise = do
          slot <- c_rt_graph_template_instance_add rt cTid
          if slot < 0
             then do
               forM_ slots (c_rt_graph_instance_remove rt)
               pure (Left (SasiPrewarmFailed name (SpiInstanceAddFailed attempt)))
             else go (attempt + 1) (slot : slots)

configuredPrewarmCount :: RTGraphAdapterOptions -> Template -> Int
configuredPrewarmCount opts tpl
  | templateWritesBuffer tpl = 1
  | otherwise                = requested
  where
    name = TemplateName (tplName tpl)
    requested =
      max 1 (Map.findWithDefault
               (raoDefaultPolyphony opts)
               name
               (raoPerTemplatePolyphony opts))

templateWritesBuffer :: Template -> Bool
templateWritesBuffer tpl =
  not (Set.null (bfBufWrites (rfBuffers (tplFootprint tpl))))

preservingHotSwapPlan
  :: RTGraphAdapterState
  -> TemplateGraph
  -> ResolveRebuildResult
  -> Either SessionRuntimeIssue PreservingHotSwapPlan
preservingHotSwapPlan current graph preview = do
  newTemplateIds <-
    either (Left . SriHotSwapInstallFailed . SasiDuplicateTemplateName) Right
      (templateIdMap graph)
  let bindings = preservedVoiceBindings preview
      slots = map vbSlotId bindings
  when (any (< 0) slots) $
    Left SriHotSwapWouldPreserveVoices
  when (Set.size (Set.fromList slots) /= length slots) $
    Left SriHotSwapWouldPreserveVoices

  statefulByTemplate <- traverse (preservedTemplateStatefulCount newTemplateIds)
    (Set.toList (Set.fromList (map vbTemplateName bindings)))
  let statefulCounts = Map.fromList statefulByTemplate
      expectedCopies =
        sum
          [ Map.findWithDefault 0 (vbTemplateName binding) statefulCounts
          | binding <- bindings
          ]
  pure PreservingHotSwapPlan
    { phspBindings               = bindings
    , phspExpectedStateCopyCount = expectedCopies
    }
  where
    oldTemplateIds = rtgasTemplateIds current

    preservedTemplateStatefulCount newTemplateIds name = do
      oldTid <- lookupTemplateId name oldTemplateIds
      newTid <- lookupTemplateId name newTemplateIds
      when (oldTid /= newTid) $
        Left SriHotSwapWouldPreserveVoices
      oldTpl <- lookupTemplate name (rtgasGraph current)
      newTpl <- lookupTemplate name graph
      count <- validatePreservingTemplate name oldTpl newTpl
      pure (name, count)

    lookupTemplateId name ids =
      maybe (Left SriHotSwapWouldPreserveVoices) Right
        (Map.lookup name ids)

preservedVoiceBindings :: ResolveRebuildResult -> [VoiceBinding]
preservedVoiceBindings preview =
  [ VoiceBinding
      { vbVoiceKey     = VoiceKey (BSC.unpack voiceKey)
      , vbSlotId       = slot
      , vbTemplateName = TemplateName (BSC.unpack templateName)
      }
  | (voiceKey, (slot, templateName)) <-
      Map.toAscList (OSC.resolveStateVoices (rrrState preview))
  ]

lookupTemplate
  :: TemplateName
  -> TemplateGraph
  -> Either SessionRuntimeIssue Template
lookupTemplate (TemplateName rawName) graph =
  maybe (Left SriHotSwapWouldPreserveVoices) Right $
    find ((== rawName) . tplName) (tgTemplates graph)

validatePreservingTemplate
  :: TemplateName
  -> Template
  -> Template
  -> Either SessionRuntimeIssue Int
validatePreservingTemplate _name oldTpl newTpl = do
  traverse_ validateStatefulNode validationNodes
  pure (length stateCopyNodes)
  where
    oldNodesByKey = Map.fromList
      [ (key, node)
      | node <- rgNodes (tplGraph oldTpl)
      , Just key <- [rnMigrationKey node]
      ]

    newNodes = rgNodes (tplGraph newTpl)
    validationNodes =
      filter (nodeKindNeedsPreservingValidation . rnKind) newNodes
    stateCopyNodes = filter (nodeKindNeedsStateCopy . rnKind) newNodes

    validateStatefulNode node
      | not (nodeKindSupportsPreservingHotSwap (rnKind node)) =
          Left SriHotSwapWouldPreserveVoices
      | otherwise =
          case rnMigrationKey node of
            Nothing ->
              Left SriHotSwapWouldPreserveVoices
            Just key ->
              case Map.lookup key oldNodesByKey of
                Nothing ->
                  Left SriHotSwapWouldPreserveVoices
                Just oldNode
                  | rnKind oldNode /= rnKind node ->
                      Left SriHotSwapWouldPreserveVoices
                  | length (rnControls oldNode) /= length (rnControls node) ->
                      Left SriHotSwapWouldPreserveVoices
                  | otherwise ->
                      Right node

nodeKindSupportsPreservingHotSwap :: NodeKind -> Bool
nodeKindSupportsPreservingHotSwap kind =
  case preservingHotSwapNodeClass kind of
    PreserveUnsupported -> False
    PreserveStateless   -> True
    PreserveStateful    -> True

nodeKindNeedsPreservingValidation :: NodeKind -> Bool
nodeKindNeedsPreservingValidation kind =
  case preservingHotSwapNodeClass kind of
    PreserveUnsupported -> True
    PreserveStateless   -> False
    PreserveStateful    -> True

nodeKindNeedsStateCopy :: NodeKind -> Bool
nodeKindNeedsStateCopy kind =
  case preservingHotSwapNodeClass kind of
    -- Unsupported kinds are still selected by
    -- nodeKindNeedsPreservingValidation and rejected before the
    -- count is used. Keeping them out of the copy count makes this
    -- predicate's narrower meaning literal.
    PreserveUnsupported -> False
    PreserveStateless   -> False
    PreserveStateful    -> True

data PreservingHotSwapNodeClass
  = PreserveUnsupported
  | PreserveStateless
  | PreserveStateful
  deriving stock (Eq, Show)

-- | Single preserving-swap classification table.
--
-- Keeping support, validation, and state-copy expectation derived
-- from this one table avoids the drift where a kind is admitted but
-- omitted from the relevant preserving-swap checks.
preservingHotSwapNodeClass :: NodeKind -> PreservingHotSwapNodeClass
preservingHotSwapNodeClass = \case
  KEnv             -> PreserveUnsupported
  KDelay           -> PreserveUnsupported
  KSmooth          -> PreserveStateful
  KPlayBufMono     -> PreserveUnsupported
  KRecordBufMono   -> PreserveUnsupported
  KSpectralFreeze  -> PreserveUnsupported
  KStaticPlugin    -> PreserveUnsupported
  KSpectralLpf     -> PreserveUnsupported
  KSinOsc          -> PreserveStateful
  KOut             -> PreserveStateless
  KGain            -> PreserveStateless
  KSawOsc          -> PreserveStateful
  KNoiseGen        -> PreserveStateful
  KLPF             -> PreserveStateful
  KAdd             -> PreserveStateless
  KBusOut          -> PreserveStateless
  KBusIn           -> PreserveStateless
  KBusInDelayed    -> PreserveStateless
  KPulseOsc        -> PreserveStateful
  KTriOsc          -> PreserveStateful
  KHPF             -> PreserveStateful
  KBPF             -> PreserveStateful
  KNotch           -> PreserveStateful

preparePreservingBuilder
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> [VoiceBinding]
  -> IO (Either SessionRuntimeIssue PreservingBuilderMeta)
preparePreservingBuilder builder opts graph bindings =
  case templateIdMap graph of
    Left duplicate ->
      pure (Left (SriHotSwapInstallFailed
        (SasiDuplicateTemplateName duplicate)))
    Right ids -> do
      loaded <- try (loadTemplateGraphWithAutoSpawns builder graph)
      case loaded of
        Left err ->
          pure (Left (SriHotSwapInstallFailed
            (SasiLoaderException (displayException (err :: SomeException)))))
        Right autoRows ->
          case autoSpawnRows graph autoRows of
            Left issue ->
              pure (Left (SriHotSwapInstallFailed issue))
            Right rows -> do
              forM_ rows $ \(_, _, slot) ->
                c_rt_graph_instance_remove builder (fromIntegral slot)
              seeded <- seedPreservedSlots builder opts graph ids bindings
              case seeded of
                Left issue ->
                  pure (Left issue)
                Right activeCounts -> do
                  prewarmed <-
                    prewarmTemplatesAfterPreserve
                      builder opts (tgTemplates graph) activeCounts
                  pure $ case prewarmed of
                    Left issue ->
                      Left (SriHotSwapInstallFailed issue)
                    Right counts ->
                      Right PreservingBuilderMeta
                        { pbmTemplateIds      = ids
                        , pbmPrewarmCounts    = counts
                        , pbmAutoSpawnedSlots =
                            Map.fromList
                              [ (name, slot) | (name, _, slot) <- rows ]
                        }

seedPreservedSlots
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> Map.Map TemplateName Int
  -> [VoiceBinding]
  -> IO (Either SessionRuntimeIssue (Map.Map TemplateName Int))
seedPreservedSlots _builder _opts _graph _ids [] =
  pure (Right Map.empty)
seedPreservedSlots builder opts graph ids bindings =
  case listToMaybe (filter (not . templateWritesBuffer) templates)
       <|> listToMaybe templates of
    Nothing ->
      pure (Left SriHotSwapWouldPreserveVoices)
    Just fillerTpl -> do
      -- The C ABI currently allocates the lowest available slot. We
      -- create short-lived filler instances so each preserved binding
      -- lands on its existing slot id, then check every returned slot
      -- against that monotonic-allocation assumption. Filler instances
      -- are removed before the builder can be published, so even a
      -- buffer-writing fallback template never runs.
      let activeCounts = Map.fromListWith (+)
            [ (vbTemplateName binding, 1 :: Int)
            | binding <- bindings
            ]
          desiredBySlot = Map.fromList
            [ (vbSlotId binding, binding)
            | binding <- bindings
            ]
          maxSlot = maximum (map vbSlotId bindings)
          fillerName = TemplateName (tplName fillerTpl)
      forM_ (zip ([0 ..] :: [Int]) templates) $ \(tid, tpl) -> do
        let name = TemplateName (tplName tpl)
            base =
              max (configuredPrewarmCount opts tpl)
                  (Map.findWithDefault 0 name activeCounts)
            count =
              if name == fillerName
                 then max base (maxSlot + 1)
                 else base
        c_rt_graph_template_set_polyphony
          builder
          (fromIntegral tid)
          (fromIntegral count)
      seeded <- seedSlots desiredBySlot fillerName maxSlot []
      case seeded of
        Left issue ->
          pure (Left issue)
        Right dummySlots -> do
          forM_ dummySlots (c_rt_graph_instance_remove builder)
          pure (Right activeCounts)
  where
    templates = tgTemplates graph

    seedSlots desiredBySlot fillerName maxSlot dummySlots =
      go 0 dummySlots
      where
        go slotIndex acc
          | slotIndex > maxSlot =
              pure (Right acc)
          | otherwise = do
              let (templateName, keepLive) =
                    case Map.lookup slotIndex desiredBySlot of
                      Just binding -> (vbTemplateName binding, True)
                      Nothing      -> (fillerName, False)
              case Map.lookup templateName ids of
                Nothing ->
                  pure (Left SriHotSwapWouldPreserveVoices)
                Just templateId -> do
                  slot <- c_rt_graph_template_instance_add
                            builder
                            (fromIntegral templateId)
                  if slot < 0 || fromIntegral slot /= slotIndex
                     then pure (Left SriHotSwapWouldPreserveVoices)
                     else go (slotIndex + 1)
                            (if keepLive then acc else slot : acc)

prewarmTemplatesAfterPreserve
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> [Template]
  -> Map.Map TemplateName Int
  -> IO (Either SessionAdapterSetupIssue (Map.Map TemplateName Int))
prewarmTemplatesAfterPreserve rt opts templates activeCounts =
  foldM step (Right Map.empty) (zip ([0 ..] :: [Int]) templates)
  where
    step (Left issue) _ =
      pure (Left issue)
    step (Right acc) (tid, tpl) = do
      let name = TemplateName (tplName tpl)
          active = Map.findWithDefault 0 name activeCounts
          count = max (configuredPrewarmCount opts tpl) active
          extra = max 0 (count - active)
          cTid = fromIntegral tid
      c_rt_graph_template_set_polyphony rt cTid (fromIntegral count)
      result <- prewarmOne rt name cTid extra
      pure $ case result of
        Left issue -> Left issue
        Right ()   -> Right (Map.insert name count acc)

runRTGraphAdapter
  :: RTGraphAdapterEnv
  -> SessionPlan
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
runRTGraphAdapter env plan = do
  st <- readIORef (rtaeState env)
  case plan of
    PlanVoiceStart templateName voiceKey initialControls ->
      runVoiceStart st templateName voiceKey initialControls

    PlanVoiceStop binding ->
      runVoiceStop st binding

    PlanControlWrite binding controlTag value ->
      runControlWrite st binding controlTag value

    PlanHotSwap mode label graph preview ->
      runHotSwap env st mode label graph preview

runVoiceStart
  :: RTGraphAdapterState
  -> TemplateName
  -> VoiceKey
  -> [(ControlTag, Value)]
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
runVoiceStart st templateName voiceKey initialControls =
  case Map.lookup templateName (rtgasTemplateIds st) of
    Nothing ->
      pure (Left (SriUnknownRuntimeTemplate templateName))
    Just templateId -> do
      slot <- c_rt_graph_realtime_reserve
                (rtgasRTGraph st)
                (fromIntegral templateId)
      if slot < 0
         then pure (Left SriVoiceAllocationFailed)
         else do
           controls <- writeInitialControls st slot templateName initialControls
           case controls of
             Left issue -> do
               c_rt_graph_realtime_cancel (rtgasRTGraph st) slot
               pure (Left issue)
             Right () -> do
               activated <- c_rt_graph_realtime_activate (rtgasRTGraph st) slot
               if activated == 1
                  then pure (Right (RuntimeCommitted
                         (CommitVoiceStarted VoiceBinding
                           { vbVoiceKey     = voiceKey
                           , vbSlotId       = fromIntegral slot
                           , vbTemplateName = templateName
                           })))
                  else do
                    c_rt_graph_realtime_cancel (rtgasRTGraph st) slot
                    pure (Left (SriRealtimeQueueFull RtOpActivate))

writeInitialControls
  :: RTGraphAdapterState
  -> CInt
  -> TemplateName
  -> [(ControlTag, Value)]
  -> IO (Either SessionRuntimeIssue ())
writeInitialControls st slot templateName =
  foldM step (Right ())
  where
    step (Left issue) _ =
      pure (Left issue)
    step (Right ()) (controlTag, value) =
      case resolveSessionControl st templateName controlTag of
        Left issue ->
          pure (Left issue)
        Right target -> do
          c_rt_graph_instance_set_control
            (rtgasRTGraph st)
            slot
            (nodeIndexCInt (targetNodeIndex target))
            (fromIntegral (targetControlSlot target))
            (CDouble value)
          pure (Right ())

runVoiceStop
  :: RTGraphAdapterState
  -> VoiceBinding
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
runVoiceStop st binding = do
  accepted <- c_rt_graph_realtime_release
                (rtgasRTGraph st)
                (fromIntegral (vbSlotId binding))
  if accepted == 1
     then pure (Right (RuntimeCommitted
            (CommitVoiceStopped (vbVoiceKey binding))))
     else pure (Left (SriRealtimeQueueFull RtOpRelease))

runControlWrite
  :: RTGraphAdapterState
  -> VoiceBinding
  -> ControlTag
  -> Value
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
runControlWrite st binding controlTag value =
  case resolveSessionControl st (vbTemplateName binding) controlTag of
    Left issue ->
      pure (Left issue)
    Right target -> do
      accepted <- c_rt_graph_realtime_set_control
                    (rtgasRTGraph st)
                    (fromIntegral (vbSlotId binding))
                    (nodeIndexCInt (targetNodeIndex target))
                    (fromIntegral (targetControlSlot target))
                    (CDouble value)
      if accepted == 1
         then pure (Right RuntimeControlWriteAccepted)
         else pure (Left (SriRealtimeQueueFull RtOpSetControl))

runHotSwap
  :: RTGraphAdapterEnv
  -> RTGraphAdapterState
  -> HotSwapInstallMode
  -> SwapLabel
  -> TemplateGraph
  -> ResolveRebuildResult
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
-- If 'installSessionGraph' fails after the loader's clear path, the
-- runtime may be in an indeterminate state while the caller-visible
-- 'SessionState' still claims the old graph. The owner treats this as
-- terminal divergence; this adapter does not attempt in-place repair.
-- This concern is specific to the rebuild branch below; the
-- preserving-only rejection returns before any clear/install attempt.
runHotSwap env current mode label graph preview
  | not (null preservedBindings) =
      case preservingHotSwapPlan current graph preview of
        Left issue ->
          pure (Left issue)
        Right plan ->
          runPreservingHotSwap env current label graph plan
  | mode == HotSwapPreservingOnly =
      pure (Left SriHotSwapRebuildForbidden)
  | otherwise = do
      installed <- installSessionGraph
                     (rtgasRTGraph current)
                     graph
                     (rtaeOptions env)
      case installed of
        Left issue ->
          pure (Left (SriHotSwapInstallFailed issue))
        Right st' -> do
          writeIORef (rtaeState env) st'
          pure (Right (RuntimeCommitted (CommitGraphInstalled label graph)))
  where
    preservedBindings = preservedVoiceBindings preview

runPreservingHotSwap
  :: RTGraphAdapterEnv
  -> RTGraphAdapterState
  -> SwapLabel
  -> TemplateGraph
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue SessionRuntimeSuccess)
runPreservingHotSwap env current label graph plan = do
  installed <- installPreservingHotSwap
                 rt
                 (rtaeOptions env)
                 graph
                 plan
  case installed of
    Left issue ->
      pure (Left issue)
    Right meta -> do
      let st' = RTGraphAdapterState
            { rtgasGraph            = graph
            , rtgasTemplateIds      = pbmTemplateIds meta
            , rtgasPrewarmCounts    = pbmPrewarmCounts meta
            , rtgasAutoSpawnedSlots = pbmAutoSpawnedSlots meta
            , rtgasRTGraph          = rt
            }
      writeIORef (rtaeState env) st'
      pure (Right (RuntimeCommitted (CommitGraphInstalled label graph)))
  where
    rt = rtgasRTGraph current

installPreservingHotSwap
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue PreservingBuilderMeta)
installPreservingHotSwap rt opts graph plan = do
  audioRunning <- c_rt_graph_audio_running rt
  if audioRunning == 0
     then installScriptedPreservingHotSwap rt opts graph plan
     else installLivePreservingHotSwap rt opts graph plan

installScriptedPreservingHotSwap
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue PreservingBuilderMeta)
installScriptedPreservingHotSwap rt opts graph plan = do
  -- Drain queued realtime voice/control commands before freezing the
  -- old world as the migration source.
  driveScriptedPreservingStep rt
  withPreparedPreservingBuilder rt opts graph plan $ \builder ->
    publishAndVerifyScriptedPreservingSwap rt builder plan

installLivePreservingHotSwap
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue PreservingBuilderMeta)
installLivePreservingHotSwap rt opts graph plan =
  withPreparedPreservingBuilder rt opts graph plan $ \builder ->
    publishAndVerifyLivePreservingSwap
      rt
      builder
      plan
      (raoHotSwapInstallTimeoutMs opts)

withPreparedPreservingBuilder
  :: Ptr RTGraph
  -> RTGraphAdapterOptions
  -> TemplateGraph
  -> PreservingHotSwapPlan
  -> (Ptr RTGraph -> IO (Either SessionRuntimeIssue ()))
  -> IO (Either SessionRuntimeIssue PreservingBuilderMeta)
withPreparedPreservingBuilder rt opts graph plan action = do
  sizing <- preservingBuilderSizing rt
  case sizing of
    Left issue ->
      pure (Left issue)
    Right (capacity, maxFrames) ->
      withRTGraph (fromIntegral capacity) (fromIntegral maxFrames) $
        \builder -> do
          prepared <- preparePreservingBuilder
                        builder
                        opts
                        graph
                        (phspBindings plan)
          case prepared of
            Left issue ->
              pure (Left issue)
            Right meta -> do
              installed <- action builder
              pure $ case installed of
                Left issue -> Left issue
                Right ()   -> Right meta

preservingBuilderSizing
  :: Ptr RTGraph
  -> IO (Either SessionRuntimeIssue (CInt, CInt))
preservingBuilderSizing rt = do
  capacity <- c_rt_graph_capacity rt
  maxFrames <- c_rt_graph_max_frames rt
  pure $
    if capacity <= 0 || maxFrames < 0
       then Left (SriHotSwapInstallFailed
              (SasiLoaderException
                "invalid RTGraph sizing for preserving hot-swap"))
       else Right (capacity, maxFrames)

publishAndVerifyScriptedPreservingSwap
  :: Ptr RTGraph
  -> Ptr RTGraph
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue ())
publishAndVerifyScriptedPreservingSwap rt builder plan = do
  acquired <- acquirePreservingSwap rt builder
  case acquired of
    Left issue ->
      pure (Left issue)
    Right swap -> do
      published <- publishPreservingSwap rt swap
      case published of
        Left issue ->
          pure (Left issue)
        Right () -> do
          installed <- forceInstallPreservingSwap rt
          case installed of
            Left issue ->
              pure (Left issue)
            Right retired ->
              verifyPreservingMigration rt retired plan

publishAndVerifyLivePreservingSwap
  :: Ptr RTGraph
  -> Ptr RTGraph
  -> PreservingHotSwapPlan
  -> Int
  -> IO (Either SessionRuntimeIssue ())
publishAndVerifyLivePreservingSwap rt builder plan timeoutMs =
  runLiveHotSwapProtocol
    LiveHotSwapProtocol
      { lhpReadGeneration =
          readSwapGeneration rt
      , lhpAcquireSwap =
          acquirePreservingSwap rt builder
      , lhpPublishSwap =
          publishPreservingSwap rt
      , lhpWaitForGeneration =
          waitForSwapGeneration rt
      , lhpCollectRetiredStats =
          collectRetiredSwapStats rt
      }
    (preservingHotSwapExpectations plan)
    timeoutMs

runLiveHotSwapProtocol
  :: Monad m
  => LiveHotSwapProtocol m swap
  -> PreservingHotSwapExpectations
  -> TimeoutMs
  -> m (Either SessionRuntimeIssue ())
runLiveHotSwapProtocol protocol expectations timeoutMs = do
  priorGeneration <- lhpReadGeneration protocol
  acquired <- lhpAcquireSwap protocol
  case acquired of
    Left issue ->
      pure (Left issue)
    Right swap -> do
      published <- lhpPublishSwap protocol swap
      case published of
        Left issue ->
          pure (Left issue)
        Right () -> do
          installed <-
            lhpWaitForGeneration protocol priorGeneration timeoutMs
          if not installed
             then
               -- Publish transferred ownership to the runtime. On
               -- timeout there is no local swap pointer to cancel; the
               -- owner must diverge rather than continue with stale
               -- session state.
               pure (Left (hotSwapInstallFailed
                 "preserving hot-swap install timed out"))
             else do
               stats <- lhpCollectRetiredStats protocol
               pure $ case stats of
                 Nothing ->
                   Left (hotSwapInstallFailed
                     "preserving hot-swap installed but retired swap was missing")
                 Just migrationStats ->
                   verifyPreservingMigrationStatsWithExpectations
                     migrationStats
                     expectations

acquirePreservingSwap
  :: Ptr RTGraph
  -> Ptr RTGraph
  -> IO (Either SessionRuntimeIssue (Ptr RTGraphSwap))
acquirePreservingSwap rt builder = do
  swap <- c_rt_graph_prepare_swap_from_graph rt builder
  pure $
    if swap == nullPtr
       then Left SriHotSwapWouldPreserveVoices
       else Right swap

publishPreservingSwap
  :: Ptr RTGraph
  -> Ptr RTGraphSwap
  -> IO (Either SessionRuntimeIssue ())
publishPreservingSwap rt swap = do
  published <- c_rt_graph_publish_swap rt swap
  if published == 1
     then pure (Right ())
     else do
       c_rt_graph_cancel_swap rt swap
       pure (Left SriHotSwapPublishRejected)

forceInstallPreservingSwap
  :: Ptr RTGraph
  -> IO (Either SessionRuntimeIssue (Ptr RTGraphSwap))
forceInstallPreservingSwap rt = do
  -- Drive the published swap through the stopped-audio callback path.
  driveScriptedPreservingStep rt
  retired <- c_rt_graph_collect_retired_swap rt
  pure $
    if retired == nullPtr
       then
         -- publish_swap transferred ownership to the runtime pending
         -- slot. There is no safe local swap pointer to cancel here;
         -- graph reset/destroy will reclaim any still-pending swap.
         Left (SriHotSwapInstallFailed
           (SasiLoaderException
             "preserving hot-swap did not retire installed swap"))
       else Right retired

verifyPreservingMigration
  :: Ptr RTGraph
  -> Ptr RTGraphSwap
  -> PreservingHotSwapPlan
  -> IO (Either SessionRuntimeIssue ())
verifyPreservingMigration rt retired plan = do
  stateCopies <- c_rt_graph_swap_migration_state_copy_count retired
  lifecycleCopies <- c_rt_graph_swap_migration_lifecycle_copy_count retired
  c_rt_graph_cancel_swap rt retired
  pure $ verifyPreservingMigrationCounts
    (fromIntegral stateCopies)
    (fromIntegral lifecycleCopies)
    (preservingHotSwapExpectations plan)

verifyPreservingMigrationStatsWithExpectations
  :: SwapMigrationStats
  -> PreservingHotSwapExpectations
  -> Either SessionRuntimeIssue ()
verifyPreservingMigrationStatsWithExpectations stats =
  verifyPreservingMigrationCounts
    (smsStateCopyCount stats)
    (smsLifecycleCopyCount stats)

verifyPreservingMigrationCounts
  :: Int
  -> Int
  -> PreservingHotSwapExpectations
  -> Either SessionRuntimeIssue ()
verifyPreservingMigrationCounts stateCopies lifecycleCopies expectations =
  if copiedEnough
     then Right ()
     else Left (hotSwapInstallFailed
            "preserving hot-swap migration was incomplete")
  where
    copiedEnough =
      lifecycleCopies >= phsePreservedBindingCount expectations
      && stateCopies >= phseExpectedStateCopyCount expectations

preservingHotSwapExpectations
  :: PreservingHotSwapPlan
  -> PreservingHotSwapExpectations
preservingHotSwapExpectations plan =
  PreservingHotSwapExpectations
    { phsePreservedBindingCount =
        length (phspBindings plan)
    , phseExpectedStateCopyCount =
        phspExpectedStateCopyCount plan
    }

hotSwapInstallFailed :: String -> SessionRuntimeIssue
hotSwapInstallFailed =
  SriHotSwapInstallFailed . SasiLoaderException

driveScriptedPreservingStep :: Ptr RTGraph -> IO ()
driveScriptedPreservingStep rt =
  -- Zero frames still drive the runtime's control-queue/RCU state
  -- machine without rendering audio. This scripted path is only valid
  -- while the audio callback is stopped; live integrations should
  -- publish and wait for the audio thread to advance the swap
  -- generation.
  c_rt_graph_process rt 0

resolveSessionControl
  :: RTGraphAdapterState
  -> TemplateName
  -> ControlTag
  -> Either SessionRuntimeIssue ControlTarget
resolveSessionControl st templateName controlTag =
  case resolveControlTarget (rtgasGraph st) templateName controlTag of
    Left issue     -> Left (SriControlTargetRejected issue)
    Right resolved -> Right resolved

nodeIndexCInt :: NodeIndex -> CInt
nodeIndexCInt (NodeIndex ix) =
  fromIntegral ix
