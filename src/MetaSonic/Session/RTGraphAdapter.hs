{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.Session.RTGraphAdapter
-- Description : Session-mode helpers for a caller-owned RTGraph.
--
-- This module starts the real-runtime side of Session Prep E without
-- creating a session owner. The functions here operate on a
-- caller-owned 'RTGraph' handle. The adapter constructor installs
-- graph metadata and returns a 'SessionRuntimeAdapter IO'; plan
-- execution lands in the following Prep E slices.
--
-- See [notes/2026-05-12-session-prep-e-rtgraph-adapter.md].

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

    -- * Setup failures
  , SessionAdapterSetupIssue (..)
  , SessionPrewarmIssue (..)

    -- * Adapter scaffold
  , newRTGraphAdapter

    -- * Session-mode graph install
  , installSessionGraph
  ) where

import           Control.DeepSeq            (NFData)
import           Control.Exception          (SomeException, displayException,
                                             try)
import           Control.Monad              (foldM, forM_)
import           Data.IORef                 (IORef, newIORef, readIORef)
import qualified Data.Map.Strict            as Map
import qualified Data.Set                   as Set
import           Foreign.C.Types            (CDouble (..), CInt)
import           Foreign.Ptr                (Ptr)
import           GHC.Generics               (Generic)

import           MetaSonic.Bridge.FFI       (RTGraph,
                                             c_rt_graph_instance_remove,
                                             c_rt_graph_instance_set_control,
                                             c_rt_graph_realtime_activate,
                                             c_rt_graph_realtime_cancel,
                                             c_rt_graph_realtime_release,
                                             c_rt_graph_realtime_reserve,
                                             c_rt_graph_realtime_set_control,
                                             c_rt_graph_template_instance_add,
                                             c_rt_graph_template_set_polyphony,
                                             loadTemplateGraphWithAutoSpawns)
import           MetaSonic.Bridge.Templates (BufferFootprint (..),
                                             ResourceFootprint (..),
                                             Template (..), TemplateGraph (..))
import           MetaSonic.ControlTarget    (ControlTarget (..),
                                             resolveControlTarget)
import           MetaSonic.Pattern          (ControlTag, TemplateName (..),
                                             Value, VoiceKey)
import           MetaSonic.Session.Runtime  (SessionRuntimeAdapter (..),
                                             RealtimeOp (..),
                                             SessionRuntimeIssue (..),
                                             SessionRuntimeSuccess (..))
import           MetaSonic.Session.Resolve  (VoiceBinding (..))
import           MetaSonic.Session.State    (SessionCommit (..),
                                             SessionPlan (..))
import           MetaSonic.Types            (NodeIndex (..))


-- | Construction-time sizing policy for session-mode graph install.
--
-- Per-template entries override 'raoDefaultPolyphony'. Values below
-- one are clamped to one to match the C ABI's polyphony policy.
data RTGraphAdapterOptions = RTGraphAdapterOptions
  { raoPerTemplatePolyphony :: !(Map.Map TemplateName Int)
  , raoDefaultPolyphony     :: !Int
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

defaultRTGraphAdapterOptions :: RTGraphAdapterOptions
defaultRTGraphAdapterOptions = RTGraphAdapterOptions
  { raoPerTemplatePolyphony = Map.empty
  , raoDefaultPolyphony     = 1
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

data SessionPrewarmIssue
  = SpiInstanceAddFailed !Int
    -- ^ One-based prewarm attempt whose
    -- 'rt_graph_template_instance_add' call returned -1.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Setup/install failures before an adapter exists.
data SessionAdapterSetupIssue
  = SasiDuplicateTemplateName !TemplateName
  | SasiLoaderException !String
    -- ^ Exception text from the underlying graph loader.
  | SasiAutoSpawnTemplateIdMismatch !Int !Int
    -- ^ Expected template id, actual template id returned by the
    -- instrumented loader.
  | SasiAutoSpawnRowCountMismatch !Int !Int
    -- ^ Expected row count, actual row count returned by the
    -- instrumented loader.
  | SasiAutoSpawnMissing !TemplateName
  | SasiPrewarmFailed !TemplateName !SessionPrewarmIssue
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Private mutable metadata captured by the IO adapter.
--
-- This is not a session owner. The pure 'SessionState' remains the
-- caller-visible source of truth; the IORef only lets future plan
-- execution slices update runtime lookup metadata after a constrained
-- graph install.
newtype RTGraphAdapterEnv = RTGraphAdapterEnv
  { rtaeState :: IORef RTGraphAdapterState
  }

-- | Install a graph in session mode and return an adapter shell for
-- 'MetaSonic.Session.Step.stepSessionCommand'.
--
-- Prep E lands this constructor before plan execution. Until the
-- voice/control execution slice fills in the cases, running the
-- adapter returns 'SriAdapterReason' rather than mutating runtime or
-- session state.
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
        (runRTGraphAdapter (RTGraphAdapterEnv ref))))

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
      result <- prewarmOne name cTid count
      pure $ case result of
        Left issue -> Left issue
        Right ()   -> Right (Map.insert name count acc)

    prewarmOne :: TemplateName -> CInt -> Int -> IO (Either SessionAdapterSetupIssue ())
    prewarmOne name cTid count =
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

    PlanHotSwap {} ->
      pure (Left (SriAdapterReason
        "RTGraphAdapter hot-swap execution not implemented"))

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
