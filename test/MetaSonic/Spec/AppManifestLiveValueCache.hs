{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : MetaSonic.Spec.AppManifestLiveValueCache
-- Description : Tests for the Phase 8h live-session value cache.
--
-- Pins the pure cache operations and the operator-facing renderer
-- behind the @values@ command, plus the producer-neutral accepted-
-- write extractors that wire OSC \/ UI \/ MIDI listeners into the
-- cache. Avoids real UDP \/ audio \/ MIDI device IO so the test stays
-- in-language.
module MetaSonic.Spec.AppManifestLiveValueCache
  ( appManifestLiveValueCacheTests
  ) where

import           Data.IORef       (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as M
import qualified Data.Set        as Set
import qualified Data.Text       as T
import           Data.Word       (Word8)

import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=), assertBool)

import           MetaSonic.App.ManifestLiveCommon
                                                (acceptedFanInControlWrite,
                                                 acceptedMIDIProducerControlWrites,
                                                 acceptedOSCControlWrite,
                                                 acceptedUIControlWrite,
                                                 liveMIDIListenerHooksForObserved)
import           MetaSonic.App.ManifestMIDIListener
                                                (ManifestMIDIListenerHooks (..),
                                                 ManifestMIDIListenerIssue (..))
import           MetaSonic.App.ManifestReloadMIDIIngress
                                                (ManifestMIDIIngressIssue (..))
import           MetaSonic.App.ManifestLiveValueCache
                                                (LiveControlValue (..),
                                                 LiveControlValueSource (..),
                                                 emptyLiveValueCache,
                                                 lookupLiveValue,
                                                 recordAcceptedWrite,
                                                 renderValuesTable,
                                                 retainSurvivingControls)
import           MetaSonic.App.ManifestReloadOSCBinding
                                                (ManifestOSCControlBinding (..))
import           MetaSonic.Bridge.Source        (MigrationKey (..))
import           MetaSonic.Pattern              (ControlTag (..),
                                                 VoiceKey (..))
import           MetaSonic.Session.Command      (SessionCommand (..))
import           MetaSonic.Session.FanIn        (SessionFanInEnqueueResult (..))
import qualified Data.ByteString.Char8       as BS

import           MetaSonic.OSC.Dispatch.Internal (DispatchIssue (..))
import           MetaSonic.Session.MIDIProducer (MIDIProducerCommandBatch (..),
                                                 MIDIProducerEnqueueResult (..),
                                                 MIDIProducerEvent (..),
                                                 MIDIProducerIssue (..),
                                                 initialMIDIProducerState)
import           MetaSonic.Session.OSCProducer  (OSCProducerEnqueueResult (..))
import           MetaSonic.Session.Queue        (CommandSequence (..),
                                                 ProducerId (..),
                                                 ProducerKind (..),
                                                 QueuedSessionCommand (..),
                                                 SessionEnqueueIssue (..),
                                                 SessionEnqueueResult (..))
import           MetaSonic.Session.UIProducer   (UIProducerEnqueueResult (..),
                                                 UIProducerIssue (..))


appManifestLiveValueCacheTests :: TestTree
appManifestLiveValueCacheTests =
  testGroup "App manifest live value cache (Phase 8h)"
  [ testGroup "recordAcceptedWrite"               recordAcceptedWriteTests
  , testGroup "retainSurvivingControls"           retainSurvivingControlsTests
  , testGroup "renderValuesTable"                 renderValuesTableTests
  , testGroup "acceptedFanInControlWrite"         acceptedFanInControlWriteTests
  , testGroup "acceptedOSCControlWrite"           acceptedOSCControlWriteTests
  , testGroup "acceptedUIControlWrite"            acceptedUIControlWriteTests
  , testGroup "acceptedMIDIProducerControlWrites" acceptedMIDIProducerControlWritesTests
  , testGroup "liveMIDIListenerHooksForObserved"  liveMIDIListenerHooksForObservedTests
  ]


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

vk :: String -> VoiceKey
vk = VoiceKey

tag :: String -> Int -> ControlTag
tag node slot = ControlTag (MigrationKey node) slot

cutoffTag, qTag, levelTag :: ControlTag
cutoffTag = tag "lpf" 0
qTag      = tag "lpf" 1
levelTag  = tag "gain" 0

binding :: ControlTag -> String -> Double -> Double -> Double -> Maybe Word8 -> ManifestOSCControlBinding
binding t name def lo hi cc = ManifestOSCControlBinding
  { mocbControlTag  = t
  , mocbDisplayName = name
  , mocbDefault     = def
  , mocbRangeMin    = lo
  , mocbRangeMax    = hi
  , mocbCC          = cc
  }

cutoffBinding, qBinding, levelBinding :: ManifestOSCControlBinding
cutoffBinding = binding cutoffTag "cutoff" 600.0 200.0  6000.0 (Just 74)
qBinding      = binding qTag      "q"      0.7   0.3    4.0    (Just 71)
levelBinding  = binding levelTag  "level"  0.2   0.0    0.5    (Just  7)


-- ---------------------------------------------------------------------------
-- recordAcceptedWrite
-- ---------------------------------------------------------------------------

recordAcceptedWriteTests :: [TestTree]
recordAcceptedWriteTests =
  [ testCase "empty cache has no entry for any voice/control" $
      lookupLiveValue (vk "v0") cutoffTag emptyLiveValueCache @?= Nothing

  , testCase "single accepted write becomes a lookup hit with source=accepted" $
      let cache = recordAcceptedWrite (vk "v0") cutoffTag 900.0 emptyLiveValueCache
      in lookupLiveValue (vk "v0") cutoffTag cache
           @?= Just (LiveControlValue 900.0 LcvsAccepted)

  , testCase "subsequent write to same voice/control overwrites prior value" $
      let c1 = recordAcceptedWrite (vk "v0") cutoffTag 900.0  emptyLiveValueCache
          c2 = recordAcceptedWrite (vk "v0") cutoffTag 1800.0 c1
      in lookupLiveValue (vk "v0") cutoffTag c2
           @?= Just (LiveControlValue 1800.0 LcvsAccepted)

  , testCase "writes to different controls coexist on the same voice" $
      let c1 = recordAcceptedWrite (vk "v0") cutoffTag 900.0 emptyLiveValueCache
          c2 = recordAcceptedWrite (vk "v0") qTag      0.4   c1
      in ( lookupLiveValue (vk "v0") cutoffTag c2
         , lookupLiveValue (vk "v0") qTag      c2
         )
           @?= ( Just (LiveControlValue 900.0 LcvsAccepted)
               , Just (LiveControlValue 0.4   LcvsAccepted)
               )

  , testCase "writes to different voices live in separate maps" $
      let c1 = recordAcceptedWrite (vk "v0") cutoffTag 900.0  emptyLiveValueCache
          c2 = recordAcceptedWrite (vk "v1") cutoffTag 2400.0 c1
      in ( lookupLiveValue (vk "v0") cutoffTag c2
         , lookupLiveValue (vk "v1") cutoffTag c2
         )
           @?= ( Just (LiveControlValue 900.0  LcvsAccepted)
               , Just (LiveControlValue 2400.0 LcvsAccepted)
               )
  ]


-- ---------------------------------------------------------------------------
-- retainSurvivingControls
-- ---------------------------------------------------------------------------

retainSurvivingControlsTests :: [TestTree]
retainSurvivingControlsTests =
  [ testCase "drops entries whose ControlTag is not in the surviving set" $
      let cache =
            recordAcceptedWrite (vk "v0") cutoffTag 900.0 $
            recordAcceptedWrite (vk "v0") qTag      0.4   $
            recordAcceptedWrite (vk "v0") levelTag  0.3
              emptyLiveValueCache
          surviving =
            Set.fromList [cutoffTag, levelTag]  -- q retired
          kept =
            retainSurvivingControls (Set.singleton (vk "v0")) surviving cache
      in ( lookupLiveValue (vk "v0") cutoffTag kept
         , lookupLiveValue (vk "v0") qTag      kept
         , lookupLiveValue (vk "v0") levelTag  kept
         )
           @?= ( Just (LiveControlValue 900.0 LcvsAccepted)
               , Nothing
               , Just (LiveControlValue 0.3 LcvsAccepted)
               )

  , testCase "drops voices not in the surviving set entirely" $
      let cache =
            recordAcceptedWrite (vk "v0") cutoffTag 900.0  $
            recordAcceptedWrite (vk "v1") cutoffTag 2400.0
              emptyLiveValueCache
          kept =
            retainSurvivingControls
              (Set.singleton (vk "v0"))
              (Set.singleton cutoffTag)
              cache
      in ( lookupLiveValue (vk "v0") cutoffTag kept
         , lookupLiveValue (vk "v1") cutoffTag kept
         )
           @?= ( Just (LiveControlValue 900.0 LcvsAccepted)
               , Nothing
               )

  , testCase "voice with no surviving entries is pruned out of the map" $
      let cache =
            recordAcceptedWrite (vk "v0") qTag 0.4 emptyLiveValueCache
          kept =
            retainSurvivingControls
              (Set.singleton (vk "v0"))
              (Set.singleton cutoffTag)  -- q retired, no survivors for v0
              cache
      in lookupLiveValue (vk "v0") qTag kept @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- renderValuesTable
-- ---------------------------------------------------------------------------

renderValuesTableTests :: [TestTree]
renderValuesTableTests =
  [ testCase "no live voices renders the empty-voices marker" $
      renderValuesTable "saw-filter-dark" [] [cutoffBinding] emptyLiveValueCache
        @?= [ "  values for saw-filter-dark:"
            , "    (no live voices)"
            ]

  , testCase "no manifest controls renders the empty-controls marker" $
      renderValuesTable "saw-filter-dark" [vk "v0"] [] emptyLiveValueCache
        @?= [ "  values for saw-filter-dark:"
            , "    (manifest binds no OSC controls)"
            ]

  , testCase "empty cache renders manifest defaults with source=default" $
      let lines' = renderValuesTable
                     "saw-filter-dark"
                     [vk "v0"]
                     [cutoffBinding, qBinding, levelBinding]
                     emptyLiveValueCache
      in do
        head lines' @?= "  values for saw-filter-dark:"
        assertContains "source=default" lines'
        -- 'renderOperatorValue' trims trailing-zero noise, so 600.0
        -- renders as "600" without a decimal point.
        assertContains "value=600"      lines'  -- cutoff default
        assertContains "value=0.7"      lines'  -- q default
        assertContains "value=0.2"      lines'  -- level default

  , testCase "accepted write renders source=accepted with the new value" $
      let cache  = recordAcceptedWrite (vk "v0") cutoffTag 1800.0 emptyLiveValueCache
          lines' = renderValuesTable
                     "saw-filter-dark"
                     [vk "v0"]
                     [cutoffBinding]
                     cache
      in do
        assertContains "source=accepted" lines'
        assertContains "value=1800"      lines'
        assertContains "/v0/lpf/0"       lines'

  , testCase "rendering reuses the operator-compact format (0.05 renders as 5e-2)" $
      let cache  = recordAcceptedWrite (vk "v0") levelTag 0.05 emptyLiveValueCache
          lines' = renderValuesTable
                     "saw-filter-dark"
                     [vk "v0"]
                     [levelBinding]
                     cache
      in assertContains "value=5e-2" lines'

  , testCase "rows preserve manifest binding order (no ControlTag sort)" $
      -- The saw/noise fixture lists controls as
      -- pitch (carrier/0), cutoff (lpf/0), q (lpf/1), level (gain/0).
      -- A ControlTag sort would move 'gain' before 'lpf' and break
      -- the 'controls' / 'values' / addressable-surface alignment
      -- pinned by 'motControls' (see Note on 'ManifestOSCIngressTarget'
      -- in 'ManifestReloadOSCBinding.hs').
      let pitchTag     = tag "carrier" 0
          pitchBinding = binding pitchTag "pitch" 220.0 55.0 880.0 Nothing
          manifestOrder =
            [pitchBinding, cutoffBinding, qBinding, levelBinding]
          lines' = renderValuesTable
                     "saw-filter-dark"
                     [vk "v0"]
                     manifestOrder
                     emptyLiveValueCache
          rowAddresses =
            [ take (length addr) (dropWhile (== ' ') row)
            | row <- drop 1 lines'  -- skip the "values for ..." header
            , let addr = takeWhile (/= ' ') (dropWhile (== ' ') row)
            ]
      in rowAddresses @?=
           [ "/v0/carrier/0"
           , "/v0/lpf/0"
           , "/v0/lpf/1"
           , "/v0/gain/0"
           ]

  , testCase "controls without CC bindings omit the cc= suffix" $
      let noCcBinding = cutoffBinding { mocbCC = Nothing }
          lines' = renderValuesTable
                     "saw-filter-dark"
                     [vk "v0"]
                     [noCcBinding]
                     emptyLiveValueCache
          rendered = unlines lines'
      in assertBool ("expected no cc= in: " <> rendered)
           (not (T.pack " cc=" `T.isInfixOf` T.pack rendered))
  ]
  where
    assertContains needle ls =
      assertBool
        ("expected " <> show needle <> " in:\n" <> unlines ls)
        (any (T.isInfixOf (T.pack needle) . T.pack) ls)


-- ---------------------------------------------------------------------------
-- acceptedFanInControlWrite (producer-neutral core projection)
-- ---------------------------------------------------------------------------

acceptedFanInControlWriteTests :: [TestTree]
acceptedFanInControlWriteTests =
  [ testCase "projects an accepted CmdControlWrite to Just (voice, tag, value)" $
      acceptedFanInControlWrite
        (acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0))
        @?= Just (vk "v0", cutoffTag, 900.0)

  , testCase "returns Nothing for an accepted non-control command (CmdVoiceOff)" $
      acceptedFanInControlWrite
        (acceptedFanIn (CmdVoiceOff (vk "v0")))
        @?= Nothing

  , testCase "returns Nothing for an enqueue-rejected command" $
      acceptedFanInControlWrite
        (rejectedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- acceptedOSCControlWrite (OSC wrapper peel)
-- ---------------------------------------------------------------------------

acceptedOSCControlWriteTests :: [TestTree]
acceptedOSCControlWriteTests =
  [ testCase "peels OSCProducerEnqueueAttempted and projects the inner result" $
      acceptedOSCControlWrite
        (OSCProducerEnqueueAttempted
           (CmdControlWrite (vk "v0") cutoffTag 900.0)
           (acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)))
        @?= Just (vk "v0", cutoffTag, 900.0)

  , testCase "returns Nothing when the inner enqueue was rejected" $
      acceptedOSCControlWrite
        (OSCProducerEnqueueAttempted
           (CmdControlWrite (vk "v0") cutoffTag 900.0)
           (rejectedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)))
        @?= Nothing

  , testCase "returns Nothing for OSCProducerDecodeRejected" $
      acceptedOSCControlWrite
        (OSCProducerDecodeRejected (DiInvalidAddressFormat (BS.pack "/bogus")))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- acceptedUIControlWrite (UI wrapper peel)
-- ---------------------------------------------------------------------------

acceptedUIControlWriteTests :: [TestTree]
acceptedUIControlWriteTests =
  [ testCase "peels UIProducerEnqueueAttempted and projects the inner result" $
      acceptedUIControlWrite
        (UIProducerEnqueueAttempted
           (CmdControlWrite (vk "v0") cutoffTag 900.0)
           (acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)))
        @?= Just (vk "v0", cutoffTag, 900.0)

  , testCase "returns Nothing when the inner enqueue was rejected" $
      acceptedUIControlWrite
        (UIProducerEnqueueAttempted
           (CmdControlWrite (vk "v0") cutoffTag 900.0)
           (rejectedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)))
        @?= Nothing

  , testCase "returns Nothing for a producer-local UIProducerRejected" $
      acceptedUIControlWrite
        (UIProducerRejected (UpiNonFiniteControlValue cutoffTag (1/0)))
        @?= Nothing
  ]


-- ---------------------------------------------------------------------------
-- acceptedMIDIProducerControlWrites (MIDI wrapper, list-valued)
-- ---------------------------------------------------------------------------

acceptedMIDIProducerControlWritesTests :: [TestTree]
acceptedMIDIProducerControlWritesTests =
  [ testCase "projects one accepted CmdControlWrite to a singleton list" $
      acceptedMIDIProducerControlWrites
        (midiAttempted
           [CmdControlWrite (vk "v0") cutoffTag 900.0]
           [acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)])
        @?= [(vk "v0", cutoffTag, 900.0)]

  , testCase "projects two accepted CmdControlWrites in order" $
      acceptedMIDIProducerControlWrites
        (midiAttempted
           [ CmdControlWrite (vk "v0") cutoffTag 900.0
           , CmdControlWrite (vk "v0") qTag      0.4
           ]
           [ acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0)
           , acceptedFanIn (CmdControlWrite (vk "v0") qTag      0.4)
           ])
        @?= [ (vk "v0", cutoffTag, 900.0)
            , (vk "v0", qTag,      0.4)
            ]

  , testCase "drops accepted non-control commands from a mixed batch" $
      acceptedMIDIProducerControlWrites
        (midiAttempted
           [ CmdVoiceOff (vk "v0")
           , CmdControlWrite (vk "v0") qTag 0.4
           ]
           [ acceptedFanIn (CmdVoiceOff (vk "v0"))
           , acceptedFanIn (CmdControlWrite (vk "v0") qTag 0.4)
           ])
        @?= [(vk "v0", qTag, 0.4)]

  , testCase "returns [] for a deferred wrapper (non-empty batch, empty results)" $
      acceptedMIDIProducerControlWrites
        (midiAttempted
           [CmdControlWrite (vk "v0") cutoffTag 900.0]
           [])
        @?= []

  , testCase "returns [] for MIDIProducerRejected" $
      acceptedMIDIProducerControlWrites
        (MIDIProducerRejected (MpiChannelFiltered 0) initialMIDIProducerState)
        @?= []
  ]


-- ---------------------------------------------------------------------------
-- Helpers — synthetic producer-enqueue result builders for tests
-- ---------------------------------------------------------------------------

testProducer :: ProducerId
testProducer = ProducerId
  { producerKind = ProducerTest
  , producerName = T.pack "values-cache-test"
  }

acceptedFanIn :: SessionCommand -> SessionFanInEnqueueResult
acceptedFanIn cmd = SessionFanInEnqueueResult
  { sfierResult = SessionEnqueued QueuedSessionCommand
      { qscSequence = CommandSequence 1
      , qscProducer = testProducer
      , qscCommand  = cmd
      }
  , sfierQueueDepth = 1
  }

rejectedFanIn :: SessionCommand -> SessionFanInEnqueueResult
rejectedFanIn cmd = SessionFanInEnqueueResult
  { sfierResult =
      SessionEnqueueRejected testProducer cmd SeiReloadInProgress
  , sfierQueueDepth = 0
  }

midiAttempted
  :: [SessionCommand]
  -> [SessionFanInEnqueueResult]
  -> MIDIProducerEnqueueResult
midiAttempted commands results =
  MIDIProducerEnqueueAttempted
    MIDIProducerCommandBatch
      { mpcbCommands = commands
      , mpcbState    = initialMIDIProducerState
      }
    results


-- ---------------------------------------------------------------------------
-- liveMIDIListenerHooksForObserved (step 3b)
--
-- The hook binds the accepted-write observer the same way
-- 'ManifestLiveSession.recordAccepted' wires the OSC hook today:
-- an 'IORef LiveValueCache' updated via 'recordAcceptedWrite'.
-- Each test drives the hook and then asserts through
-- 'lookupLiveValue' so the projection-to-cache loop is what is pinned,
-- not a raw triple buffer.
-- ---------------------------------------------------------------------------

liveMIDIListenerHooksForObservedTests :: [TestTree]
liveMIDIListenerHooksForObservedTests =
  [ testCase "accepted CmdControlWrite updates the LiveValueCache" $ do
      ref <- newIORef emptyLiveValueCache
      let hooks = liveMIDIListenerHooksForObserved (recordInto ref)
      mmlhOnAccepted hooks
        (acceptedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0))
      cache <- readIORef ref
      lookupLiveValue (vk "v0") cutoffTag cache
        @?= Just (LiveControlValue 900.0 LcvsAccepted)

  , testCase "accepted non-control command leaves the cache untouched" $ do
      ref <- newIORef emptyLiveValueCache
      let hooks = liveMIDIListenerHooksForObserved (recordInto ref)
      mmlhOnAccepted hooks
        (acceptedFanIn (CmdVoiceOff (vk "v0")))
      cache <- readIORef ref
      lookupLiveValue (vk "v0") cutoffTag cache @?= Nothing

  , testCase "rejected enqueue leaves the cache untouched" $ do
      ref <- newIORef emptyLiveValueCache
      let hooks = liveMIDIListenerHooksForObserved (recordInto ref)
      mmlhOnAccepted hooks
        (rejectedFanIn (CmdControlWrite (vk "v0") cutoffTag 900.0))
      cache <- readIORef ref
      lookupLiveValue (vk "v0") cutoffTag cache @?= Nothing

  , testCase "issue path does not touch the cache" $ do
      ref <- newIORef emptyLiveValueCache
      let hooks = liveMIDIListenerHooksForObserved (recordInto ref)
      mmlhOnIssue hooks (MmliIngressIssue (MmiiChannelFiltered 0))
      mmlhOnIssue hooks
        (MmliEnqueueRejected
           (CmdControlWrite (vk "v0") cutoffTag 900.0)
           SeiReloadInProgress)
      mmlhOnIssue hooks (MmliIgnoredEvent (MIDIProducerNoteOn 0 60 64))
      cache <- readIORef ref
      lookupLiveValue (vk "v0") cutoffTag cache @?= Nothing
  ]
  where
    recordInto ref voice ctag value =
      modifyIORef' ref (recordAcceptedWrite voice ctag value)
