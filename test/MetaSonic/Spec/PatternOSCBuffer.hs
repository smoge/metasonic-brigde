{-# LANGUAGE LambdaCase #-}

-- | Pattern corpus, OSC wire/listener, buffer, PlayBuf, RecordBuf, and SpectralFreeze tests.
module MetaSonic.Spec.PatternOSCBuffer where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (isInfixOf, sort)
import           Control.Concurrent        (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception         (try)
import           Control.Monad             (forM_)
import           Foreign.C.Types           (CDouble (..), CFloat (..), CLLong)
import           Foreign.Marshal.Alloc     (allocaBytes)
import           Foreign.Marshal.Array     (peekArray)
import           Foreign.Ptr               (castPtr)
import           Data.IORef                (modifyIORef', newIORef, readIORef)
import           System.Timeout            (timeout)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Buffer
import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import qualified MetaSonic.OSC.Dispatch          as OSC
import qualified MetaSonic.OSC.Dispatch.Internal as OSCI
import qualified MetaSonic.OSC.Listen            as OSC
import qualified MetaSonic.OSC.Wire              as OSC
import           MetaSonic.Pattern
import           MetaSonic.Pattern.Corpus
import           MetaSonic.Types
import           MetaSonic.Spec.CoreShared
import           MetaSonic.Spec.Driver

import qualified Data.ByteString           as OBS
import qualified Data.ByteString.Char8     as OBSC

------------------------------------------------------------
-- Phase 6.A.2: pattern corpus
--
-- Three verification layers:
--   1. Deterministic expansion: 'expandPattern' over the fixed
--      'corpusRange' produces an inline-pinned event list per row.
--   2. Corpus shape: each row's compiled 'TemplateGraph' carries the
--      kernels / template-count / ordering hypothesized in the
--      Phase 6.A.2 design note.
--   3. Driver-stub feasibility: 'checkDriverFeasibility' walks each
--      row's events and confirms every PEControlWrite / PEVoiceOff
--      has a prior PEVoiceOn for the same VoiceKey, every TemplateName
--      resolves against patternTemplates, every ControlTag's NodeTag
--      resolves to a tagged node in the referenced template, and
--      SamplePos is non-decreasing.
------------------------------------------------------------

patternCorpusTests :: TestTree
patternCorpusTests = testGroup "Phase 6.A.2: pattern corpus"
  [ testGroup "deterministic expansion pins"
      [ testCase "droneVibrato" $
          expandPattern droneVibrato corpusRange @?= droneVibratoEvents
      , testCase "arpeggioSendReturn" $
          expandPattern arpeggioSendReturn corpusRange @?= arpeggioSendReturnEvents
      , testCase "polyphonicStab" $
          expandPattern polyphonicStab corpusRange @?= polyphonicStabEvents
      , testCase "hotSwapEdit" $
          expandPattern hotSwapEdit corpusRange @?= hotSwapEditEvents
      , testCase "layeredEnsemble" $
          expandPattern layeredEnsemble corpusRange @?= layeredEnsembleEvents
      , testCase "spectralFreezePad" $
          expandPattern spectralFreezePad corpusRange @?= spectralFreezePadEvents
      ]

  , testGroup "corpus shape pins"
      [ testCase "droneVibrato: one template named 'drone'" $ do
          let names = map tplName (tgTemplates (patternTemplates droneVibrato))
          names @?= ["drone"]

      , testCase "arpeggioSendReturn: voice + fx; fx claims RBusInLpfGainOut" $ do
          let tg   = patternTemplates arpeggioSendReturn
              names = sort (map tplName (tgTemplates tg))
          names @?= ["fx", "voice"]
          -- fx must come after voice (voice writes bus 5, fx reads it).
          map tplName (tgTemplates tg) @?= ["voice", "fx"]
          let fxKernels =
                [ rrKernel r
                | t <- tgTemplates tg
                , tplName t == "fx"
                , r <- rgRuntimeRegions (tplGraph t)
                ]
          assertBool
            ("expected RBusInLpfGainOut in fx kernels: " <> show fxKernels)
            (RBusInLpfGainOut `elem` fxKernels)

      , testCase "polyphonicStab: audio-modulated Gain blocks RNoiseLpfGainOut" $ do
          let tg      = patternTemplates polyphonicStab
              names   = map tplName (tgTemplates tg)
              kernels = concat
                [ map rrKernel (rgRuntimeRegions (tplGraph t))
                | t <- tgTemplates tg
                ]
          names @?= ["stab"]
          assertBool
            ("expected RNoiseLpfGainOut absent (envelope-modulated Gain): "
             <> show kernels)
            (RNoiseLpfGainOut `notElem` kernels)

      , testCase "hotSwapEdit: 'drone' template and swap payload" $ do
          let names = map tplName (tgTemplates (patternTemplates hotSwapEdit))
          names @?= ["drone"]
          let swapPayloadNames =
                [ map tplName (tgTemplates tg2)
                | (_, PEHotSwap _ tg2) <- hotSwapEditEvents
                ]
          swapPayloadNames @?= [["drone"]]

      , testCase "layeredEnsemble: bass + pad + fx; fx is scheduled last" $ do
          let tg     = patternTemplates layeredEnsemble
              names  = map tplName (tgTemplates tg)
          sort names @?= ["bass", "fx", "pad"]
          -- fx reads bus 5, bass and pad both write it; fx must
          -- follow both in the inter-template precedence order.
          last names @?= "fx"
          let fxKernels =
                [ rrKernel r
                | t <- tgTemplates tg
                , tplName t == "fx"
                , r <- rgRuntimeRegions (tplGraph t)
                ]
          assertBool
            ("expected RBusInLpfGainOut in ensemble fx kernels: "
             <> show fxKernels)
            (RBusInLpfGainOut `elem` fxKernels)

      , testCase "spectralFreezePad: template carries KSpectralFreeze Barrier" $ do
          let tg = patternTemplates spectralFreezePad
              names = map tplName (tgTemplates tg)
          -- §6.D second-kind contract: the row carries both
          -- spectral templates so the survey aggregate is
          -- contiguous; the "texture" template still pins the
          -- freeze kernel as the barrier-classified one.
          names @?= ["texture", "lpf-bed"]
          case filter ((== "texture") . tplName) (tgTemplates tg) of
            [tpl] -> do
              let rg = tplGraph tpl
                  kinds = map rnKind (rgNodes rg)
                  segments = segmentByBarrier rg
                  freezeInBarrier =
                    any (\seg -> case seg of
                      Barrier r ->
                        any (\ix ->
                          any (\n -> rnIndex n == ix
                                    && rnKind n == KSpectralFreeze)
                              (rgNodes rg))
                            (rrNodes r)
                      FreeSegment _ -> False)
                        segments
              assertBool
                ("expected KSpectralFreeze in row kinds: " <> show kinds)
                (KSpectralFreeze `elem` kinds)
              assertBool
                ("expected spectral region Barrier; segments = "
                 <> show (length segments))
                freezeInBarrier
            _ -> assertFailure "expected exactly one 'texture' template"
      ]

  , testGroup "driver-stub feasibility"
      [ testCase "droneVibrato"       $
          checkDriverFeasibility droneVibrato       droneVibratoEvents       @?= []
      , testCase "arpeggioSendReturn" $
          checkDriverFeasibility arpeggioSendReturn arpeggioSendReturnEvents @?= []
      , testCase "polyphonicStab"     $
          checkDriverFeasibility polyphonicStab     polyphonicStabEvents     @?= []
      , testCase "hotSwapEdit"        $
          checkDriverFeasibility hotSwapEdit        hotSwapEditEvents        @?= []
      , testCase "layeredEnsemble"    $
          checkDriverFeasibility layeredEnsemble    layeredEnsembleEvents    @?= []
      , testCase "spectralFreezePad"  $
          checkDriverFeasibility spectralFreezePad  spectralFreezePadEvents  @?= []
      ]

  , testGroup "range-aware patternEvents"
      [ testCase "empty range yields no events" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 0) (SamplePos 0))
          @?= []

      , testCase "range entirely after all events yields no events" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 200000) (SamplePos 300000))
          @?= []

      , testCase "subrange [90000, 100000) isolates the 96000 control write" $
          expandPattern droneVibrato
            (SampleRange (SamplePos 90000) (SamplePos 100000))
          @?=
            [ ( SamplePos 96000
              , PEControlWrite (VoiceKey "v0")
                  (ControlTag (MigrationKey "lpf") 0) 800.0
              )
            ]

      , testCase
          "patternEvents itself respects the range (no expandPattern clamp)"
          $ do
            let r = SampleRange (SamplePos 90000) (SamplePos 100000)
            patternEvents droneVibrato r @?=
              [ ( SamplePos 96000
                , PEControlWrite (VoiceKey "v0")
                    (ControlTag (MigrationKey "lpf") 0) 800.0
                )
              ]

      , testCase
          "polyphonicStab subrange [10000, 30000) captures all 8 voice-offs"
          $ do
            let r = SampleRange (SamplePos 10000) (SamplePos 30000)
                evs = expandPattern polyphonicStab r
            length evs @?= 8
            all (\(SamplePos t, _) -> t == 24000) evs @?= True
      ]

  , testGroup "driver-stub negative cases"
      [ testCase "out-of-range ctSlot reports InvalidControlSlot" $ do
          -- droneVibrato's "lpf" node has 2 controls (freq + q);
          -- slot 99 is well out of range.
          let badEvents =
                [ (SamplePos 0,
                     PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "lpf") 99, 1500.0)])
                ]
              badPattern = droneVibrato
                { patternEvents = const badEvents }
          case checkDriverFeasibility badPattern badEvents of
            [InvalidControlSlot
              (TemplateName "drone") (MigrationKey "lpf") 99 _] ->
              pure ()
            issues ->
              assertFailure $
                "expected InvalidControlSlot, got: " <> show issues

      , testCase "unknown NodeTag reports UnknownControlNode" $ do
          let badEvents =
                [ (SamplePos 0,
                     PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                       [(ControlTag (MigrationKey "no-such-tag") 0,
                         1.0)])
                ]
              badPattern = droneVibrato
                { patternEvents = const badEvents }
          case checkDriverFeasibility badPattern badEvents of
            [UnknownControlNode
              (TemplateName "drone")
              (MigrationKey "no-such-tag")] ->
              pure ()
            issues ->
              assertFailure $
                "expected UnknownControlNode, got: " <> show issues

      , testCase
          "hot-swap losing an open voice's template reports HotSwapTemplateLost"
          $ do
            -- Open a "drone" voice, then swap to a payload that
            -- only carries a "stab" template. The validator should
            -- flag the orphaned voice and drop it from the open
            -- set; the subsequent PEControlWrite then surfaces as
            -- UnknownVoiceForWrite.
            let orphanTg = patternTemplates polyphonicStab
                badEvents =
                  [ (SamplePos 0,
                       PEVoiceOn (TemplateName "drone") (VoiceKey "v0")
                         [(ControlTag (MigrationKey "lpf") 0, 1500.0)])
                  , (SamplePos 96000,
                       PEHotSwap (SwapLabel "drop-drone") orphanTg)
                  , (SamplePos 120000,
                       PEControlWrite (VoiceKey "v0")
                         (ControlTag (MigrationKey "lpf") 0) 2000.0)
                  ]
                badPattern = droneVibrato
                  { patternEvents = const badEvents }
            checkDriverFeasibility badPattern badEvents @?=
              [ HotSwapTemplateLost (VoiceKey "v0") (TemplateName "drone")
              , UnknownVoiceForWrite (VoiceKey "v0")
              ]
      ]
  ]

------------------------------------------------------------
-- Phase 6.B.2a: OSC wire + dispatch
--
-- Three test groups:
--   1. Pure wire parser: hand-crafted byte sequences round-trip
--      to expected OscMessage values; bundles and unsupported
--      type tags are rejected explicitly.
--   2. Dispatch against the arpeggio-send-return fx template
--      (which carries 'tagged "lpf" / "outgain"') registered as
--      one voice key. Positive case writes a control; negative
--      cases mirror the §6.A DriverIssue shape.
--   3. OSC-safe identifier profile boundary cases.
------------------------------------------------------------

oscWireAndDispatchTests :: TestTree
oscWireAndDispatchTests = testGroup "Phase 6.B.2a: OSC wire + dispatch"
  [ wireTests
  , dispatchTests
  , identifierProfileTests
  ]

wireTests :: TestTree
wireTests = testGroup "wire parser"
  [ testCase "parses /fx0/lpf/0 ,f 1500.0" $
      OSC.parseMessage messageBytesFx0LpfFloat
        @?= Right (OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                   [OSC.OscArgFloat 1500.0])

  , testCase "parses /fx0/outgain/0 ,i 42" $
      OSC.parseMessage messageBytesFx0OutgainInt
        @?= Right (OSC.OscMessage (OBSC.pack "/fx0/outgain/0")
                                   [OSC.OscArgInt 42])

  , testCase "rejects an OSC bundle prefix" $
      case OSC.parseMessage (oscString (OBSC.pack "#bundle")) of
        Left  err -> assertBool ("expected bundle rejection, got: " <> err)
                                ("bundle" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects an unsupported type tag" $ do
      let bytes = OBS.concat
            [ oscString (OBSC.pack "/foo")
            , oscString (OBSC.pack ",s")
            , oscString (OBSC.pack "hello")
            ]
      case OSC.parseMessage bytes of
        Left  _   -> pure ()
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects a truncated argument" $ do
      -- ,f promises 4 argument bytes; supply only 2.
      let bytes = OBS.concat
            [ oscString (OBSC.pack "/foo")
            , oscString (OBSC.pack ",f")
            , OBS.pack [0x44, 0xBB]
            ]
      case OSC.parseMessage bytes of
        Left  _   -> pure ()
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects trailing bytes after declared arguments" $ do
      -- A valid /fx0/lpf/0 ,f 1500.0 message followed by 4
      -- extra bytes the wire spec does not authorize.
      let bytes = OBS.concat
            [ messageBytesFx0LpfFloat
            , OBS.pack [0x00, 0x00, 0x00, 0x00]
            ]
      case OSC.parseMessage bytes of
        Left err -> assertBool ("expected trailing-byte rejection, got: " <> err)
                               ("trailing" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)

  , testCase "rejects non-zero bytes in OSC-string padding" $ do
      -- '/foo' is 4 bytes + 1 NUL = 5 raw bytes; padding is
      -- 3 bytes to reach the next 4-byte boundary. A conforming
      -- producer fills them with NUL; we plant 0xFF in the
      -- first padding slot and assert the parser rejects it.
      let badAddrField =
            OBS.pack [0x2F, 0x66, 0x6F, 0x6F, 0x00, 0xFF, 0x00, 0x00]
          bytes = OBS.concat
            [ badAddrField
            , oscString (OBSC.pack ",f")
            , floatBytes1500
            ]
      case OSC.parseMessage bytes of
        Left err -> assertBool ("expected padding-zero rejection, got: " <> err)
                               ("padding" `isInfixOf` err)
        Right msg -> assertFailure ("expected Left, got: " <> show msg)
  ]

-- ----- Dispatch against a 6.A corpus template ----------------

-- Build a ResolveState that registers voice key "fx0" against
-- the arpeggio-send-return fx template. The voice's runtime
-- slot id is fixed at 1 (the IO layer would have this from a
-- prior rt_graph_realtime_reserve call). The fixture's
-- invariant is that "fx0" is OSC-safe; the @error@ below fires
-- only if 'registerVoice' is reused with a malformed key later.
arpeggioFxResolveState :: OSC.ResolveState
arpeggioFxResolveState =
  case OSC.registerVoice (OBSC.pack "fx0") 1 (OBSC.pack "fx")
         (OSC.emptyResolveState (patternTemplates arpeggioSendReturn)) of
    Right rs  -> rs
    Left  iss -> error $ "test fixture: " <> show iss

dispatchTests :: TestTree
dispatchTests = testGroup "dispatch against arpeggio-send-return/fx"
  [ testCase "control write resolves to the fx template's lpf slot 0" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                [OSC.OscArgFloat 1500.0]
      case OSC.dispatch arpeggioFxResolveState msg of
        Right (OSC.DAControlWrite
                  { OSC.daSlotId     = 1
                  , OSC.daControlIdx = 0
                  , OSC.daValue      = v
                  }) -> v @?= 1500.0
        other -> assertFailure ("unexpected dispatch result: " <> show other)

  , testCase "int argument coerces to Double" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/outgain/0")
                                [OSC.OscArgInt 1]
      case OSC.dispatch arpeggioFxResolveState msg of
        Right da -> OSC.daValue da @?= 1.0
        Left  i  -> assertFailure ("expected success, got: " <> show i)

  , testCase "symbolic control decoder extracts producer-facing target" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/1")
                                [OSC.OscArgInt 42]
      case OSCI.decodeSymbolicControlWrite msg of
        Right write -> do
          OSCI.scwVoiceKey write @?= VoiceKey "fx0"
          OSCI.scwControlTag write
            @?= ControlTag (MigrationKey "lpf") 1
          OSCI.scwValue write @?= 42.0
        Left issue ->
          assertFailure ("expected symbolic control write, got: " <> show issue)

  , testCase "symbolic control decoder rejects malformed messages directly" $ do
      let cases =
            [ ( "reserved voice"
              , OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiReservedPathSegment (OBSC.pack "swap")
              )
            , ( "invalid node tag"
              , OSC.OscMessage (OBSC.pack "/fx0/bad name/0")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiIdentifierProfile (OBSC.pack "bad name")
              )
            , ( "non-integer slot"
              , OSC.OscMessage (OBSC.pack "/fx0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
              , OSC.DiSlotNotInteger (OBSC.pack "cutoff")
              )
            , ( "zero args"
              , OSC.OscMessage (OBSC.pack "/fx0/lpf/0") []
              , OSC.DiUnsupportedArgShape 0
              )
            ]
      forM_ cases $ \(label, msg, expected) ->
        case OSCI.decodeSymbolicControlWrite msg of
          Left issue ->
            issue @?= expected
          Right write ->
            assertFailure
              (label <> ": expected symbolic decode rejection, got "
               <> show write)

  , testCase "unknown voice key surfaces as DiUnknownVoice" $ do
      let msg = OSC.OscMessage (OBSC.pack "/no-such/lpf/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnknownVoice (OBSC.pack "no-such"))

  , testCase "unknown node tag surfaces as DiUnknownNodeTag" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/no-such/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnknownNodeTag (OBSC.pack "fx0")
                                        (OBSC.pack "no-such"))

  , testCase "out-of-range slot surfaces as DiInvalidControlSlot" $ do
      -- The fx template's lpf node has 2 controls (freq, q);
      -- slot 99 is out of range.
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/99")
                                [OSC.OscArgFloat 1.0]
      case OSC.dispatch arpeggioFxResolveState msg of
        Left (OSC.DiInvalidControlSlot
                  v t 99 _) -> do
          v @?= OBSC.pack "fx0"
          t @?= OBSC.pack "lpf"
        other -> assertFailure ("unexpected dispatch result: " <> show other)

  , testCase "reserved path segment 'swap' surfaces as DiReservedPathSegment" $ do
      let msg = OSC.OscMessage (OBSC.pack "/swap/lpf/0")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiReservedPathSegment (OBSC.pack "swap"))

  , testCase "malformed address surfaces as DiInvalidAddressFormat" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf") [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiInvalidAddressFormat (OBSC.pack "/fx0/lpf"))

  , testCase "non-integer slot surfaces as DiSlotNotInteger" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/cutoff")
                                [OSC.OscArgFloat 1.0]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiSlotNotInteger (OBSC.pack "cutoff"))

  , testCase "zero arguments surface as DiUnsupportedArgShape" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0") []
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnsupportedArgShape 0)

  , testCase "dispatch still resolves before checking argument shape" $ do
      let msg = OSC.OscMessage (OBSC.pack "/no-such/lpf/0") []
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnknownVoice (OBSC.pack "no-such"))

  , testCase "two arguments surface as DiUnsupportedArgShape" $ do
      let msg = OSC.OscMessage (OBSC.pack "/fx0/lpf/0")
                                [OSC.OscArgFloat 1.0, OSC.OscArgInt 2]
      OSC.dispatch arpeggioFxResolveState msg
        @?= Left (OSC.DiUnsupportedArgShape 2)
  ]

-- ----- OSC-safe identifier profile ---------------------------

identifierProfileTests :: TestTree
identifierProfileTests = testGroup "OSC-safe identifier profile"
  [ testCase "accepts plain ASCII alphanumeric" $
      OSC.isOscSafeIdentifier (OBSC.pack "fx0") @?= True

  , testCase "accepts underscore and hyphen" $ do
      OSC.isOscSafeIdentifier (OBSC.pack "snare_hi") @?= True
      OSC.isOscSafeIdentifier (OBSC.pack "kick-1")   @?= True

  , testCase "rejects empty string" $
      OSC.isOscSafeIdentifier OBS.empty @?= False

  , testCase "rejects strings longer than 16 bytes" $
      OSC.isOscSafeIdentifier (OBSC.pack "abcdefghijklmnopq")  -- 17
        @?= False

  , testCase "rejects strings containing '/'" $
      OSC.isOscSafeIdentifier (OBSC.pack "foo/bar") @?= False

  , testCase "rejects strings containing spaces" $
      OSC.isOscSafeIdentifier (OBSC.pack "foo bar") @?= False

  , testCase "registerVoice accepts an OSC-safe key" $
      case OSC.registerVoice (OBSC.pack "v0") 1 (OBSC.pack "drone")
             (OSC.emptyResolveState (patternTemplates droneVibrato)) of
        Right _   -> pure ()
        Left  iss -> assertFailure (show iss)

  , testCase "registerVoice rejects a reserved word" $
      OSC.registerVoice (OBSC.pack "swap") 1 (OBSC.pack "fx")
        (OSC.emptyResolveState (patternTemplates arpeggioSendReturn))
        @?= Left (OSC.DiReservedPathSegment (OBSC.pack "swap"))

  , testCase "registerVoice rejects an identifier-profile violation" $
      case OSC.registerVoice (OBSC.pack "bad name") 1 (OBSC.pack "fx")
             (OSC.emptyResolveState (patternTemplates arpeggioSendReturn)) of
        Left (OSC.DiIdentifierProfile k) -> k @?= OBSC.pack "bad name"
        other -> assertFailure (show other)

  , testCase "registerVoiceUnchecked stays reachable in state but not via dispatch" $ do
      -- Defense-in-depth: even if internal code installs a key
      -- outside the OSC-safe profile via the escape hatch, the
      -- dispatch path-segment validator catches non-conforming
      -- segments before the lookup runs. The registered-but-
      -- unreachable voice is documentation of the design
      -- property, not a separate gate.
      let rs = OSCI.registerVoiceUnchecked
                 (OBSC.pack "bad name") 1 (OBSC.pack "fx")
                 (OSC.emptyResolveState (patternTemplates arpeggioSendReturn))
          msg = OSC.OscMessage (OBSC.pack "/bad/lpf/0")
                                [OSC.OscArgFloat 1.0]
      -- 'bad' is OSC-safe (dispatch never sees 'bad name'),
      -- so the path doesn't match any registered key and the
      -- voice-lookup miss surfaces.
      OSC.dispatch rs msg
        @?= Left (OSC.DiUnknownVoice (OBSC.pack "bad"))
  ]

------------------------------------------------------------
-- Phase 6.B.2b: OSC listener (bracketed UDP)
--
-- Four tests:
--   1. Bracket cleanup: withOscListener returns; the listener
--      thread and socket are torn down.
--   2. Loopback: a UDP packet sent to the bound port reaches the
--      SetControlFn hook with the resolved (slot, node, slot,
--      value) tuple.
--   3. Malformed packet: junk bytes surface as LiParseFailure
--      via the issue hook and do not kill the listener — a
--      subsequent valid packet still dispatches.
--   4. Queue-full: a SetControlFn returning False surfaces as
--      LiQueueFull via the issue hook, not as an exception.
--
-- Tests use port 0 (OS-assigned) so they never collide with each
-- other or with anything bound on a fixed port. A 1-second
-- timeout wraps the blocking takeMVars so a regression that
-- breaks the listener hangs the test instead of running forever.
------------------------------------------------------------

oscListenerTests :: TestTree
oscListenerTests = testGroup "Phase 6.B.2b: OSC listener (bracketed UDP)"
  [ testCase "bracket cleanup: body return tears down listener" $ do
      rsRef <- newIORef arpeggioFxResolveState
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> pure True
            , OSC.lhOnIssue    = \_ -> pure ()
            }
      result <- OSC.withOscListenerHooks hooks rsRef
                  (OSC.defaultListenerConfig 0)
                  (\_info -> pure (42 :: Int))
      result @?= 42

  , testCase "loopback packet reaches the SetControlFn hook" $ do
      rsRef    <- newIORef arpeggioFxResolveState
      received <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \slotId nodeIx ctrlSlot val -> do
                putMVar received (slotId, nodeIx, ctrlSlot, val)
                pure True
            , OSC.lhOnIssue = \_ -> pure ()
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mTuple <- timeout 1000000 (takeMVar received)
            case mTuple of
              Just (slotId, _node, ctrlSlot, val) -> do
                slotId   @?= 1
                ctrlSlot @?= 0
                val      @?= 1500.0
              Nothing ->
                assertFailure
                  "listener did not invoke SetControlFn within 1s"

  , testCase "malformed packet surfaces as LiParseFailure; listener continues" $ do
      rsRef  <- newIORef arpeggioFxResolveState
      issues <- newIORef []
      validDone <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> do
                putMVar validDone ()
                pure True
            , OSC.lhOnIssue = \i -> modifyIORef' issues (i :)
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            -- Junk bytes: no NUL, no valid OSC structure.
            sendUdpLoopback (OSC.liBoundPort info)
                            (OBS.pack [0x01, 0x02, 0x03, 0x04])
            -- Then a well-formed packet to prove the listener
            -- survived and is still processing.
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mDone <- timeout 1000000 (takeMVar validDone)
            case mDone of
              Just () -> pure ()
              Nothing ->
                assertFailure
                  "valid packet was not dispatched after malformed one"
      issueList <- readIORef issues
      assertBool ("expected at least one LiParseFailure issue, got: "
                  <> show issueList)
                 (any isParseFailure issueList)

  , testCase "queue-full surfaces as LiQueueFull, not an exception" $ do
      rsRef  <- newIORef arpeggioFxResolveState
      issues <- newEmptyMVar
      let hooks = OSC.ListenerHooks
            { OSC.lhSetControl = \_ _ _ _ -> pure False
              -- ^ pretend the realtime queue is always full
            , OSC.lhOnIssue    = putMVar issues
            }
      OSC.withOscListenerHooks hooks rsRef (OSC.defaultListenerConfig 0)
        $ \info -> do
            sendUdpLoopback (OSC.liBoundPort info) messageBytesFx0LpfFloat
            mIssue <- timeout 1000000 (takeMVar issues)
            case mIssue of
              Just (OSC.LiQueueFull 1 _ 0) -> pure ()
              other ->
                assertFailure $
                  "expected LiQueueFull, got: " <> show other
  ]
  where
    isParseFailure (OSC.LiParseFailure _) = True
    isParseFailure _                      = False

------------------------------------------------------------
-- Phase 6.B.3: end-to-end OSC loopback verification
--
-- Drives the production listener against a real loaded
-- TemplateGraph, sends a UDP packet, and verifies the realtime
-- queue actually applied the control write — by reading bus
-- samples before and after and asserting the peak amplitude
-- changed in the predicted direction.
--
-- The hook layer is used only for thread-synchronisation: the
-- mock SetControlFn calls the real c_rt_graph_realtime_set_control
-- (the same call the production listener would make) and ALSO
-- signals an MVar so the test thread knows when to render the
-- post-OSC block. This proves the full receive → parse →
-- dispatch → FFI path without depending on threadDelay, and
-- without standing up external OSC tooling or audio hardware.
------------------------------------------------------------

oscEndToEndTests :: TestTree
oscEndToEndTests = testGroup "Phase 6.B.3: OSC end-to-end loopback"
  [ testCase "UDP /v0/outgain/0 0.1 changes the bus-0 peak amplitude" $ do
      let nframes  = 256
          sizeOfF :: Int
          sizeOfF = 4

          -- A tiny tagged graph: 440 Hz sine through a scalar
          -- gain (tagged "outgain") to hardware bus 0. Default
          -- gain 0.5, so the rendered peak is ~0.5 before the
          -- OSC write and ~0.1 after.
          graph = runSynth $ do
            o <- sinOsc 440.0 0.0
            g <- tagged "outgain" (gain o 0.5)
            out 0 g

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \handle -> do
        loadTemplateGraph handle tg
        -- loadTemplateGraph auto-spawns instance 0 of each
        -- template; slot id 0 references the auto-spawn.

        rs0 <-
          case OSC.registerVoice (OBSC.pack "v0") 0 (OBSC.pack "default")
                 (OSC.emptyResolveState tg) of
            Right rs  -> pure rs
            Left  iss -> assertFailure (show iss)
                         >> error "unreachable"
        rsRef <- newIORef rs0

        -- Synchronisation hook. Wraps the production
        -- 'defaultListenerHooks' so we exercise the exact FFI
        -- call the CLI uses, then signals an MVar so the test
        -- knows when to render the post-OSC block.
        setCtrlDone <- newEmptyMVar
        let baseHooks = OSC.defaultListenerHooks handle
            setCtrl slotId nodeIx ctrlSlot val = do
              ok <- OSC.lhSetControl baseHooks
                      slotId nodeIx ctrlSlot val
              putMVar setCtrlDone ()
              pure ok
            hooks = baseHooks { OSC.lhSetControl = setCtrl }

        OSC.withOscListenerHooks hooks rsRef
          (OSC.defaultListenerConfig 0) $ \info -> do

          -- Render an initial block at the default gain (0.5)
          -- and capture the peak amplitude.
          c_rt_graph_process handle (fromIntegral nframes)
          allocaBytes (nframes * sizeOfF) $ \buf -> do
            _ <- c_rt_graph_read_bus handle 0
                   (fromIntegral nframes) (castPtr buf)
            initial <- peekArray nframes (buf :: PtrCFloat)
            let initialPeak =
                  maximum (map (\(CFloat x) -> abs x) initial)
            assertBool
              ("initial peak (gain=0.5) should be > 0.4, got "
               <> show initialPeak)
              (initialPeak > 0.4)

            -- Send the OSC packet: /v0/outgain/0 ,f 0.1
            -- The big-endian bit pattern for 0.1f is 0x3DCCCCCD.
            let packet = OBS.concat
                  [ oscString (OBSC.pack "/v0/outgain/0")
                  , oscString (OBSC.pack ",f")
                  , OBS.pack [0x3D, 0xCC, 0xCC, 0xCD]
                  ]
            sendUdpLoopback (OSC.liBoundPort info) packet

            -- Wait for the listener thread to receive the
            -- packet and finish the FFI call. 1-second timeout
            -- means a regression that breaks the listener
            -- fails the test fast instead of hanging.
            mDone <- timeout 1000000 (takeMVar setCtrlDone)
            case mDone of
              Just () -> pure ()
              Nothing ->
                assertFailure
                  "listener did not call FFI within 1s"

            -- Render another block. The realtime queue has
            -- the new gain (0.1) enqueued; rt_graph_process
            -- drains it before rendering.
            c_rt_graph_process handle (fromIntegral nframes)
            _ <- c_rt_graph_read_bus handle 0
                   (fromIntegral nframes) (castPtr buf)
            changed <- peekArray nframes (buf :: PtrCFloat)
            let changedPeak =
                  maximum (map (\(CFloat x) -> abs x) changed)
            assertBool
              ("post-OSC peak (gain=0.1) should be in (0.05, 0.2), got "
               <> show changedPeak)
              (changedPeak > 0.05 && changedPeak < 0.2)
  ]

------------------------------------------------------------
-- Phase 6.B.4: --osc-listen port parser regression tests
--
-- 'parseListenerPort' is the library-side validator that the
-- '--osc-listen [PORT]' CLI option uses to reject malformed or
-- out-of-range tokens. The CLI used to silently fall back to the
-- default port on bad input; these tests pin the strict behaviour.
------------------------------------------------------------

oscPortParserTests :: TestTree
oscPortParserTests = testGroup "Phase 6.B.4: --osc-listen port parser"
  [ testCase "accepts canonical port" $
      OSC.parseListenerPort "7000" @?= Just 7000

  , testCase "accepts low end of range" $
      OSC.parseListenerPort "1" @?= Just 1

  , testCase "accepts high end of range" $
      OSC.parseListenerPort "65535" @?= Just 65535

  , testCase "rejects zero" $
      OSC.parseListenerPort "0" @?= Nothing

  , testCase "rejects out-of-range numeric" $
      OSC.parseListenerPort "70000" @?= Nothing

  , testCase "rejects six-digit overflow guard" $
      OSC.parseListenerPort "100000" @?= Nothing

  , testCase "rejects non-digit token" $
      OSC.parseListenerPort "foo" @?= Nothing

  , testCase "rejects mixed digits and letters" $
      OSC.parseListenerPort "7000x" @?= Nothing

  , testCase "rejects empty string" $
      OSC.parseListenerPort "" @?= Nothing

  , testCase "rejects negative" $
      OSC.parseListenerPort "-7000" @?= Nothing
  ]

------------------------------------------------------------
-- Phase 6.C.3a: buffer pool wrapper tests
--
-- Exercises MetaSonic.Bridge.Buffer (alloc / load / clear)
-- against the C++ buffer pool ABI. No kernel involvement —
-- these tests verify the FFI return codes are translated to
-- BufferIssue exceptions correctly.
------------------------------------------------------------

bufferPoolTests :: TestTree
bufferPoolTests = testGroup "Phase 6.C.3a: buffer pool wrapper"
  [ testCase "alloc returns ID 0 on a fresh graph" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 256
        bufferId buf @?= 0

  , testCase "alloc twice returns IDs 0 and 1" $
      withRTGraph 16 256 $ \rt -> do
        b0 <- allocBuffer rt 256
        b1 <- allocBuffer rt 256
        (bufferId b0, bufferId b1) @?= (0, 1)

  , testCase "alloc past pool capacity raises BiPoolFull" $
      withRTGraph 16 256 $ \rt -> do
        -- The pool is 64 wide. Filling it exactly should succeed;
        -- the 65th call must throw BiPoolFull.
        forM_ [0 .. 63 :: Int] $ \_ -> allocBuffer rt 1
        result <- try (allocBuffer rt 1)
        case result of
          Left BiPoolFull -> pure ()
          Left e          -> assertFailure $
            "expected BiPoolFull, got " <> show e
          Right b         -> assertFailure $
            "expected BiPoolFull, got Buffer " <> show (bufferId b)

  , testCase "loadBuffer rejects an unallocated ID" $
      withRTGraph 16 256 $ \rt -> do
        -- Construct a Buffer handle that has never been allocated.
        let fake = Buffer 99
        result <- try (loadBuffer rt fake [1.0, 2.0, 3.0])
        case result of
          Left (BiUnknownBufferId i) -> i @?= 99
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId 99, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "loadBuffer rejects frame_count exceeding capacity" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 4
        result <- try (loadBuffer rt buf [1, 2, 3, 4, 5, 6])
        case result of
          Left (BiFrameCountExceedsBuffer n) -> n @?= 6
          Left e                             -> assertFailure $
            "expected BiFrameCountExceedsBuffer, got " <> show e
          Right ()                           -> assertFailure
            "expected BiFrameCountExceedsBuffer, got success"

  , testCase "allocBuffer rejects negative frame count" $
      withRTGraph 16 256 $ \rt -> do
        result <- try (allocBuffer rt (-1))
        case result of
          Left (BiInvalidFrameCount n) -> n @?= (-1)
          Left e                       -> assertFailure $
            "expected BiInvalidFrameCount (-1), got " <> show e
          Right b                      -> assertFailure $
            "expected BiInvalidFrameCount, got Buffer " <> show b

  , testCase "clear-then-load reports BiUnknownBufferId" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 4
        clearBuffer rt buf
        result <- try (loadBuffer rt buf [1, 2, 3])
        case result of
          Left (BiUnknownBufferId i) -> i @?= bufferId buf
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "clearBuffer on unallocated ID raises BiUnknownBufferId" $
      withRTGraph 16 256 $ \rt -> do
        result <- try (clearBuffer rt (Buffer 5))
        case result of
          Left (BiUnknownBufferId i) -> i @?= 5
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId 5, got " <> show e
          Right _                    -> assertFailure
            "expected BiUnknownBufferId, got success"

  , testCase "alloc, clear, then alloc again reuses ID 0" $
      withRTGraph 16 256 $ \rt -> do
        b0 <- allocBuffer rt 64
        clearBuffer rt b0
        b1 <- allocBuffer rt 64
        bufferId b1 @?= 0
  ]

------------------------------------------------------------
-- Phase 6.C.3a: PlayBufMono end-to-end tests
--
-- Drives the real audio kernel against a loaded buffer:
-- load known samples, build playBufMono -> out, render one
-- block, assert bus-0 matches the loaded samples within
-- linear-interpolation tolerance, and counter-confirm that
-- the kernel actually read the buffer (rather than emitting
-- silent zeros that happened to match).
------------------------------------------------------------

playBufMonoTests :: TestTree
playBufMonoTests = testGroup "Phase 6.C.3a: PlayBufMono kernel"
  [ testCase "loads a 256-frame table and plays it forward" $ do
      let nframes  = 256
          sizeOfF :: Int
          sizeOfF = 4
          -- A 256-sample sine table. The kernel reads at rate=1.0
          -- starting at frame 0, so bus-0 should reproduce the
          -- table exactly (linear-interpolation between adjacent
          -- equal samples — rate=1.0 — is a no-op).
          table =
            [ sin (2 * pi * fromIntegral (i :: Int) / 256)
            | i <- [0 .. nframes - 1]
            ]
          graph = runSynthWithBuffer 0 $ \buf -> do
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        -- §6.C.3b: buffer pool is now keyed off the RTGraph handle,
        -- so alloc-before-loadTemplateGraph also works. The
        -- ordering here is historical — kept because the
        -- surrounding test already reads cleaner this way.
        loadTemplateGraph rt tg
        buf <- allocBuffer rt nframes
        loadBuffer rt buf table
        bufferId buf @?= 0

        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        -- Counter-confirmed validation: the kernel must have
        -- read every output sample from the buffer. Without
        -- this assertion an all-zeros output would pass the
        -- value comparison below (every sample of the sine
        -- table near the zero crossing is small).
        readCount    @?= fromIntegral nframes
        invalidCount @?= 0

        allocaBytes (nframes * sizeOfF) $ \buf' -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr buf')
          rendered <- peekArray nframes (buf' :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("rendered output should match the loaded sine table "
             <> "to within 1e-5 tolerance")
            (all (\(a, b) -> abs (a - b) < 1.0e-5)
                 (zip rcvs (map realToFrac table)))

  , testCase "unallocated buffer ID emits zeros + increments invalid-read counter" $ do
      let nframes  = 128
          sizeOfF :: Int
          sizeOfF = 4
          -- Reference Buffer 99 — well past the allocated set.
          graph = runSynth $ do
            s <- playBufMono (Buffer 99) (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= 0
        invalidCount @?= fromIntegral nframes

        allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bufPtr)
          rendered <- peekArray nframes (bufPtr :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            "unallocated ID must emit silence"
            (all (== 0.0) rcvs)

  , testCase "clear-then-render emits zeros + increments invalid-read counter" $ do
      let nframes  = 64
          sizeOfF :: Int
          sizeOfF = 4
          -- Allocate, load, clear *before* loading the graph so
          -- the configured control-0 value points at a cleared
          -- buffer ID. The kernel hits the invalid-read path.
          table = replicate nframes 0.5
          graphAt buf = runSynth $ do
            s <- playBufMono buf (Param 1.0) (Param 0) (Param 0)
            out 0 s

      withRTGraph 16 nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        loadBuffer  rt buf table
        clearBuffer rt buf

        tg <- case compileTemplateGraph [("default", graphAt buf)] of
          Right t  -> pure t
          Left err -> assertFailure err >> error "unreachable"

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        readCount    <- c_rt_graph_test_buffer_read_count    rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= 0
        invalidCount @?= fromIntegral nframes

        allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bufPtr)
          rendered <- peekArray nframes (bufPtr :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            "cleared buffer must emit silence"
            (all (== 0.0) rcvs)

  , testCase "start_frame seeds the playhead at instance reset" $
      -- 8-frame buffer played back from frame 3 with rate=1.0,
      -- loop=0. Output: samples[3..7] then silence past the end.
      -- 5 in-bounds reads (frames 3..7) and 3 past-the-end reads.
      let table     = [10, 20, 30, 40, 50, 60, 70, 80] :: [Float]
          nframes   = length table
          expected  = [40, 50, 60, 70, 80, 0, 0, 0] :: [Float]
      in runPlayBufScenario table 1.0 3.0 0.0 nframes expected 5 3
           "start_frame=3"

  , testCase "loop_flag=1 wraps back to start_frame past the end" $
      -- 4-frame buffer rendered for 12 samples with loop=1: every
      -- output sample is a valid read after wrap.
      let table    = [1, 2, 3, 4] :: [Float]
          expected = [1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4] :: [Float]
      in runPlayBufScenario table 1.0 0.0 1.0 12 expected 12 0
           "loop wrap"

  , testCase "loop_flag=0 goes silent past the last frame (one-shot)" $
      -- Same 4-frame buffer, loop=0, 8 samples: 4 in-bounds reads
      -- then 4 past-the-end zero emits.
      let table    = [1, 2, 3, 4] :: [Float]
          expected = [1, 2, 3, 4, 0, 0, 0, 0] :: [Float]
      in runPlayBufScenario table 1.0 0.0 0.0 8 expected 4 4
           "one-shot boundary"

  , testCase "fractional rate yields linear interpolation" $
      -- 8-frame table of even integers, rate=0.5: positions are
      -- 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5 — all in-bounds; every
      -- output sample counts as a valid read.
      let table    = [0, 2, 4, 6, 8, 10, 12, 14] :: [Float]
          expected = [0, 1, 2, 3, 4, 5, 6, 7] :: [Float]
      in runPlayBufScenario table 0.5 0.0 0.0 8 expected 8 0
           "fractional rate / linear interp"

  , testCase "negative rate is clamped to 0 (playhead frozen)" $
      -- rate=-1.0 clamps to 0 every sample; the playhead never
      -- advances and the kernel re-emits samples[0] = 10.
      let table    = [10, 20, 30, 40] :: [Float]
          expected = replicate 8 10 :: [Float]
      in runPlayBufScenario table (-1.0) 0.0 0.0 8 expected 8 0
           "negative rate clamp"

  , -- Regression test for the §6.C.2 contract: buffer_id is
    -- consulted at instance reset, never re-read per block. Build
    -- a graph that references Buffer 0 (filled with 7.0); load
    -- Buffer 1 with a different constant (99.0); render once and
    -- confirm output is 7.0; then live-write controls[0] = 1.0
    -- through rt_graph_instance_set_control and render again. The
    -- output must still be 7.0 — a regression that re-reads
    -- controls[0] per block would flip to 99.0 here.
    testCase "live set_control on slot 0 does not retarget buffer_id" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          tableA = replicate nframes (7.0 :: Float)
          tableB = replicate nframes (99.0 :: Float)
          graph = runSynth $ do
            -- loop=1 so the entire 64-sample render reads valid
            -- samples; rate=1.0; start_frame=0.
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
          playBufIx =
            case [ rnIndex n
                 | tpl <- tgTemplates tg
                 , n   <- rgNodes (tplGraph tpl)
                 , rnKind n == KPlayBufMono
                 ] of
              [NodeIndex i] -> i
              other         -> error $
                "expected one PlayBufMono node, got " <> show other

      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        -- §6.C.3b: the buffer pool is keyed off the RTGraph
        -- handle now, so alloc-before-load also works. Kept
        -- post-load for readability — the surrounding test
        -- builds the graph and the buffers in the same logical
        -- step.
        bufA <- allocBuffer rt nframes
        bufB <- allocBuffer rt nframes
        bufferId bufA @?= 0
        bufferId bufB @?= 1
        loadBuffer rt bufA tableA
        loadBuffer rt bufB tableB

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bufPtr)
              rendered <- peekArray nframes (bufPtr :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        -- Block 1: kernel reads frozen buffer_id = 0, expects 7.0.
        c_rt_graph_process rt (fromIntegral nframes)
        block1 <- readBlock
        assertBool
          ("first block must come from buffer 0 (all 7.0); got "
           <> show (take 4 block1) <> " ...")
          (all (\x -> abs (x - 7.0) < 1.0e-5) block1)

        -- Live-write controls[0] = 1.0 on the PlayBufMono node.
        -- A kernel that re-reads controls[0] per block would now
        -- play from buffer 1 (all 99.0); a kernel that respects
        -- the §6.C.2 contract stays on buffer 0.
        c_rt_graph_instance_set_control rt 0
          (fromIntegral playBufIx) 0 (CDouble 1.0)

        c_rt_graph_process rt (fromIntegral nframes)
        block2 <- readBlock
        assertBool
          ("second block must STILL come from buffer 0 (all 7.0) "
           <> "after live set_control on slot 0; got "
           <> show (take 4 block2) <> " ... "
           <> "(a value near 99.0 means buffer_id was re-read)")
          (all (\x -> abs (x - 7.0) < 1.0e-5) block2)

        -- Counter sanity: 2 blocks × nframes valid reads, no
        -- invalid reads. A regression that took the invalid-read
        -- path would not pass this either.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= 0

  , -- §6.C.3b slice 1: the buffer pool is keyed off the RTGraph
    -- handle, not RTGraphState, so a c_rt_graph_clear must leave
    -- the allocated buffers (and the per-handle counters)
    -- intact. Regression test against a future change that puts
    -- the pool back on RTGraphState.
    testCase "buffer pool survives c_rt_graph_clear" $
      withRTGraph 16 256 $ \rt -> do
        buf <- allocBuffer rt 8
        loadBuffer rt buf [1, 2, 3, 4, 5, 6, 7, 8]

        c_rt_graph_clear rt

        -- The allocated slot is still in use, so a fresh alloc
        -- must return ID 1 (not reuse 0). A pool wipe would
        -- return ID 0 here.
        buf2 <- allocBuffer rt 8
        bufferId buf2 @?= 1
        -- And the original slot's samples are still loaded; if
        -- the pool had been wiped, loadBuffer against `buf`
        -- (ID 0) would now throw BiUnknownBufferId.
        loadBuffer rt buf [9, 10, 11, 12, 13, 14, 15, 16]

  , -- §6.C.3b slice 1: hot-swap survival. Build a graph that
    -- references Buffer 0, load + render one block, run a full
    -- prepare_swap_from_graph + publish_swap + install cycle
    -- (which moves the old RTGraphState into the retire slot),
    -- render again with the SAME buffer ID still resolving to
    -- the SAME samples. A regression that put the pool back on
    -- RTGraphState would either crash on the second render
    -- (slot 0 unallocated in the new world) or emit silence
    -- (invalid-read path).
    testCase "buffer pool survives prepare_swap / publish_swap" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          fill = replicate nframes (4.25 :: Float)
          graphRef = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graphRef)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let capacity = templateGraphBuilderCapacity tg + 4

      withRTGraph capacity nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf fill

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              rendered <- peekArray nframes (bp :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        block1 <- readBlock
        assertBool
          ("pre-swap block should render the fill (4.25); got "
           <> show (take 4 block1))
          (all (\x -> abs (x - 4.25) < 1.0e-5) block1)

        -- Run a full swap cycle through the public Haskell helper:
        -- prepare from the same template (the buffer reference
        -- carries across as a normal control[0] = 0 setup), publish,
        -- and let process_graph install on the next block.
        published <- hotSwapTemplateGraph rt capacity nframes tg
        published @?= True
        c_rt_graph_process rt (fromIntegral nframes)
        gen <- readSwapGeneration rt
        gen @?= 1

        -- Render once more — the new world's PlayBufMono kernel
        -- should resolve buffer 0 and read the SAME samples.
        block2 <- readBlock
        assertBool
          ("post-swap block must still render the fill (4.25) — "
           <> "buffer pool was retired with old RTGraphState; got "
           <> show (take 4 block2))
          (all (\x -> abs (x - 4.25) < 1.0e-5) block2)

        -- Counter-confirm: two blocks × nframes valid reads
        -- accumulate across the swap. The new RTGraphState gets a
        -- fresh playhead (instance reset on install), but the
        -- handle-scoped counters do NOT reset — the same way the
        -- buffer pool itself does not reset.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= 0

        _ <- collectRetiredSwapStats rt
        pure ()

  , -- §6.C.3b slice 2 retire-mid-render lifecycle. Alloc two
    -- buffers with distinguishable fills, build a graph that
    -- references buffer 0, render one block (assert fill 7.0),
    -- retire buffer 0 while audio is conceptually running,
    -- render another block (the kernel must take the
    -- invalid-read path, emit zeros, tick the invalid counter),
    -- collect the retired slot (succeeds because process_graph
    -- between retire and collect advanced the
    -- buffer-retire-generation counter), re-alloc, confirm we
    -- get ID 0 back with fresh empty storage.
    testCase "retire / collect lifecycle reclaims a slot live-safely" $ do
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          fillA = replicate nframes (7.0 :: Float)
          fillB = replicate nframes (99.0 :: Float)
          graph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 1.0)
            out 0 s

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf0 <- allocBuffer rt nframes
        buf1 <- allocBuffer rt nframes
        bufferId buf0 @?= 0
        bufferId buf1 @?= 1
        loadBuffer rt buf0 fillA
        loadBuffer rt buf1 fillB

        loadTemplateGraph rt tg

        let readBlock = allocaBytes (nframes * sizeOfF) $ \bp -> do
              _ <- c_rt_graph_read_bus rt 0
                     (fromIntegral nframes) (castPtr bp)
              rendered <- peekArray nframes (bp :: PtrCFloat)
              pure (map (\(CFloat x) -> x) rendered)

        -- Block 1: kernel reads buffer 0 → fill A.
        c_rt_graph_process rt (fromIntegral nframes)
        block1 <- readBlock
        assertBool
          ("pre-retire block must read fill A (7.0); got "
           <> show (take 4 block1))
          (all (\x -> abs (x - 7.0) < 1.0e-5) block1)

        -- Live retire. Audio thread (conceptually running) is now
        -- between blocks; any captured samples.data() pointer is
        -- out of scope. The next kernel call must see Retired.
        retireBuffer rt buf0

        -- Collect IMMEDIATELY — the audio thread has not crossed
        -- a block boundary since retire, so the slot is still
        -- live and the call must fail with BiCollectStillLive.
        early <- try (collectRetiredBuffer rt buf0)
        case early of
          Left (BiCollectStillLive i) -> i @?= bufferId buf0
          Left e -> assertFailure $
            "expected BiCollectStillLive before a block ran, got "
              <> show (e :: BufferIssue)
          Right () -> assertFailure
            "collect must reject a retired slot before a block has run"

        -- Block 2: kernel sees Retired through the acquire-load
        -- and takes the invalid-read path. fillA is still in
        -- the slot's samples vector (retire doesn't touch
        -- storage), but the kernel never accesses it.
        c_rt_graph_process rt (fromIntegral nframes)
        block2 <- readBlock
        assertBool
          ("post-retire block must emit silence; got "
           <> show (take 4 block2))
          (all (== 0.0) block2)

        -- Now collect succeeds — buffer-retire-generation
        -- advanced when process_graph ticked at the top of
        -- block 2.
        collectRetiredBuffer rt buf0

        -- Re-alloc must return ID 0 (slot is back to Unallocated).
        -- A regression that left the slot Retired would return
        -- ID 2 here (next free past the still-allocated buf1).
        buf0' <- allocBuffer rt nframes
        bufferId buf0' @?= 0

        -- The fresh alloc zero-initialises samples; nothing
        -- carries over from fillA. Load a third pattern just to
        -- confirm the slot is actually writable again, then
        -- render and assert.
        loadBuffer rt buf0' (replicate nframes 0.25)
        c_rt_graph_process rt (fromIntegral nframes)
        block3 <- readBlock
        assertBool
          ("post-realloc block must read the new fill (0.25); got "
           <> show (take 4 block3))
          (all (\x -> abs (x - 0.25) < 1.0e-5) block3)

        -- Counter sanity. Two valid render blocks (block 1 + block 3)
        -- and one invalid render block (block 2). The retire/collect
        -- cycle itself ticks no read counters.
        readCount    <- c_rt_graph_test_buffer_read_count         rt
        invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
        readCount    @?= fromIntegral (2 * nframes)
        invalidCount @?= fromIntegral nframes

  , -- §6.C.3b slice 2: collect-without-retire is BiNotRetired,
    -- not BiCollectStillLive. Tests that the wrapper distinguishes
    -- the two failure modes correctly.
    testCase "collectRetiredBuffer on an Allocated slot raises BiNotRetired" $
      withRTGraph 16 64 $ \rt -> do
        buf <- allocBuffer rt 8
        result <- try (collectRetiredBuffer rt buf)
        case result of
          Left (BiNotRetired i) -> i @?= bufferId buf
          Left e                -> assertFailure $
            "expected BiNotRetired, got " <> show (e :: BufferIssue)
          Right ()              -> assertFailure
            "collect must reject a slot that was never retired"

  , -- §6.C.3b slice 2: clearBuffer is stopped-audio-only and now
    -- refuses to touch Retired slots — callers must go through
    -- collectRetiredBuffer to recycle a retired slot.
    testCase "clearBuffer rejects a Retired slot with BiUnknownBufferId" $
      withRTGraph 16 64 $ \rt -> do
        buf <- allocBuffer rt 8
        retireBuffer rt buf
        result <- try (clearBuffer rt buf)
        case result of
          Left (BiUnknownBufferId i) -> i @?= bufferId buf
          Left e                     -> assertFailure $
            "expected BiUnknownBufferId on a retired slot, got "
              <> show (e :: BufferIssue)
          Right ()                   -> assertFailure
            "clear must reject a retired slot"
  ]

-- | Test helper: render `nframes` of a `playBufMono` graph over a
-- single-template world, with the buffer's samples loaded and the
-- four `playBufMono` controls fixed to producer-provided defaults.
-- Asserts the rendered bus-0 output matches `expected` to within
-- 1e-5 and counter-confirms via @rt_graph_test_buffer_read_count@
-- (so an all-zeros regression cannot pass a value comparison).
runPlayBufScenario
  :: [Float]    -- ^ buffer samples
  -> Double     -- ^ rate
  -> Double     -- ^ start_frame argument (Param)
  -> Double     -- ^ loop_flag (Param)
  -> Int        -- ^ frames to render
  -> [Float]    -- ^ expected bus-0 output
  -> Int        -- ^ expected valid read count (buffer_read_count delta)
  -> Int        -- ^ expected invalid read count (buffer_invalid_read_count delta)
  -> String     -- ^ scenario label (used in failure messages)
  -> IO ()
runPlayBufScenario
    table rate start loopFlag nframes expected
    expectedValid expectedInvalid label = do
  let bufFrames = length table
      sizeOfF :: Int
      sizeOfF = 4
      graph = runSynthWithBuffer 0 $ \buf -> do
        s <- playBufMono buf (Param rate) (Param start) (Param loopFlag)
        out 0 s

  tg <- case compileTemplateGraph [("default", graph)] of
    Right t  -> pure t
    Left err -> assertFailure err >> error "unreachable"

  let totalNodes =
        sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

  withRTGraph totalNodes nframes $ \rt -> do
    loadTemplateGraph rt tg
    buf <- allocBuffer rt bufFrames
    loadBuffer rt buf table
    bufferId buf @?= 0

    c_rt_graph_process rt (fromIntegral nframes)
    readCount    <- c_rt_graph_test_buffer_read_count         rt
    invalidCount <- c_rt_graph_test_buffer_invalid_read_count rt
    -- Counter-confirmed validation: lock the exact read/invalid
    -- mix so a regression that emits zeros via a different code
    -- path (e.g. the kernel taking the wrong branch) cannot pass
    -- silently. See [feedback_counter_confirmed_validation.md].
    readCount    @?= fromIntegral expectedValid
    invalidCount @?= fromIntegral expectedInvalid

    allocaBytes (nframes * sizeOfF) $ \bufPtr -> do
      _ <- c_rt_graph_read_bus rt 0
             (fromIntegral nframes) (castPtr bufPtr)
      rendered <- peekArray nframes (bufPtr :: PtrCFloat)
      let rcvs = map (\(CFloat x) -> x) rendered
      assertBool
        (label <> ": rendered output mismatch.\n"
         <> "expected: " <> show expected <> "\n"
         <> "got:      " <> show rcvs)
        (all (\(a, b) -> abs (a - b) < 1.0e-5)
             (zip rcvs expected))

-- | Test helper: allocate a Buffer (without an RTGraph available)
-- so that the SynthM closure in the test reads identically to
-- the producer-side flow. The actual allocation happens at test
-- time; this just hands the test a stable id.
runSynthWithBuffer :: Int -> (Buffer -> SynthM ()) -> SynthGraph
runSynthWithBuffer bid k = runSynth (k (Buffer bid))

------------------------------------------------------------
-- Phase 6.C.4 follow-up: RecordBufMono kernel.
--
-- Pins the surface and a minimum-viable end-to-end render:
-- the kernel writes signal_in into an Allocated slot
-- sample-by-sample, advances the per-instance write head,
-- forwards signal_in to the audio output unchanged, and ticks
-- buffer_write_count per valid sample. The full record-then-
-- playback / retire-during-write / loop wrap / one-shot
-- boundary / live set_control regression / same-buffer
-- rejection / scheduler band coverage lands in the test-suite
-- commit alongside this slice.
------------------------------------------------------------

recordBufMonoSkeletonTests :: TestTree
recordBufMonoSkeletonTests =
  testGroup "Phase 6.C.4 follow-up: RecordBufMono kernel"
  [ testCase "inferEff produces a BufWrite on the buffer id" $ do
      let g = runSynth $ do
            src <- sinOsc 440.0 0.0
            mon <- recordBufMono (Buffer 7) src (Param 0.0)
            out 0 mon
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          fp = resourceFootprint ir
      bfBufWrites       (rfBuffers fp) @?= S.singleton 7
      bfBufReads        (rfBuffers fp) @?= S.empty
      bfBufDelayedReads (rfBuffers fp) @?= S.empty

  , testCase "kindSpec / portInfo agree on KRecordBufMono shape" $ do
      -- Cross-check the per-kind table against the contract
      -- pinned in the design note. ksAudioArity drives every
      -- post-IR site that walks input ports; ksControlArity
      -- drives the default-controls vector size.
      ksTag          (kindSpec KRecordBufMono) @?= 21
      ksRate         (kindSpec KRecordBufMono) @?= SampleRate
      ksAudioArity   (kindSpec KRecordBufMono) @?= 2
      ksControlArity (kindSpec KRecordBufMono) @?= 3
      ksLabel        (kindSpec KRecordBufMono) @?= "recordBufMono"
      portInfo KRecordBufMono (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "signal_in")
      portInfo KRecordBufMono (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "loop_flag")
      portInfo KRecordBufMono (PortIndex 2) @?= Nothing

  , testCase "kernel writes signal_in and passes it through unchanged" $ do
      -- A graph that records a constant 0.25 into a 64-sample
      -- buffer and routes the pass-through to bus 0. After one
      -- block:
      --   * bus 0 must read 0.25 everywhere (pass-through).
      --   * buffer_write_count must equal nframes (every sample
      --     hit the valid-write path).
      --   * buffer_invalid_write_count must be 0 (slot stays
      --     Allocated for the whole block).
      let nframes = 64
          sizeOfF :: Int
          sizeOfF = 4
          graph = runSynth $ do
            mon <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            out 0 mon

      tg <- case compileTemplateGraph [("default", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf (replicate nframes 0.0)

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

        writeCount        <- c_rt_graph_test_buffer_write_count          rt
        invalidWriteCount <- c_rt_graph_test_buffer_invalid_write_count  rt
        writeCount        @?= fromIntegral nframes
        invalidWriteCount @?= 0

        allocaBytes (nframes * sizeOfF) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("monitor output must equal signal_in (0.25); got "
             <> show (take 4 rcvs))
            (all (\x -> abs (x - 0.25) < 1.0e-5) rcvs)

  , -- §6.C.4 follow-up: record-then-playback, single block,
    -- two templates referencing the same buffer. The §6.C.4
    -- precedence union puts the writer template before the
    -- reader, so within one process_graph call the writer
    -- fills the buffer and the reader reads what was just
    -- written. Counter-confirmed both sides.
    testCase "record-then-playback within one block" $ do
      let nframes = 32
          sizeOfF :: Int
          sizeOfF = 4
          writerGraph = runSynth $ do
            -- recordBufMono is a sink-like writer with a
            -- pass-through output we ignore here.
            _ <- recordBufMono (Buffer 0) (Param 0.375) (Param 0.0)
            pure ()
          readerGraph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s

      tg <- case compileTemplateGraph
                   [ ("writer", writerGraph)
                   , ("reader", readerGraph) ] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- §6.C.4 precedence union: writer must precede reader.
      let names = map tplName (tgTemplates tg)
      assertEqual "writer must precede reader after topo-sort"
        ["writer", "reader"] names

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf (replicate nframes 0.0)

        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

        writeCount <- c_rt_graph_test_buffer_write_count        rt
        readCount  <- c_rt_graph_test_buffer_read_count         rt
        invalidW   <- c_rt_graph_test_buffer_invalid_write_count rt
        invalidR   <- c_rt_graph_test_buffer_invalid_read_count  rt
        writeCount @?= fromIntegral nframes
        readCount  @?= fromIntegral nframes
        invalidW   @?= 0
        invalidR   @?= 0

        allocaBytes (nframes * sizeOfF) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
          assertBool
            ("reader must read back the recorded 0.375 from "
             <> "buffer 0 (pre-load was zeros); got "
             <> show (take 4 rcvs))
            (all (\x -> abs (x - 0.375) < 1.0e-5) rcvs)

  , -- §6.C.4 follow-up: retire-during-write. Render block 1
    -- (writer ticks valid count), retire the buffer, render
    -- block 2 (writer ticks invalid count, storage untouched),
    -- collect and re-alloc, render block 3 (valid count
    -- resumes). Mirrors the §6.C.3b retire-during-read test
    -- exactly.
    testCase "retire-during-write takes the invalid path; collect re-arms" $ do
      let nframes = 32
          -- Loop so the write head wraps within a block and the
          -- re-allocated slot is immediately writable again. A
          -- one-shot writer's head would be parked at the end of
          -- the buffer after block 1, and the kernel state
          -- survives retire / collect / re-alloc (we don't
          -- migrate writer state — Note [Per-node RecordBufMono
          -- state]). Looping avoids that interaction here and
          -- keeps the test scoped to the retire semantics.
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        loadBuffer rt buf (replicate nframes 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w1 <- c_rt_graph_test_buffer_write_count          rt
        i1 <- c_rt_graph_test_buffer_invalid_write_count  rt
        w1 @?= fromIntegral nframes
        i1 @?= 0

        retireBuffer rt buf
        c_rt_graph_process rt (fromIntegral nframes)
        w2 <- c_rt_graph_test_buffer_write_count          rt
        i2 <- c_rt_graph_test_buffer_invalid_write_count  rt
        -- Block 2 took the invalid path on every sample; the
        -- write counter must not have moved.
        w2 @?= w1
        i2 @?= fromIntegral nframes

        collectRetiredBuffer rt buf
        buf' <- allocBuffer rt nframes
        bufferId buf' @?= 0
        loadBuffer rt buf' (replicate nframes 0.0)

        c_rt_graph_process rt (fromIntegral nframes)
        w3 <- c_rt_graph_test_buffer_write_count          rt
        i3 <- c_rt_graph_test_buffer_invalid_write_count  rt
        -- After collect + re-alloc, the writer resumes valid
        -- writes (the kernel instance's write_head is whatever
        -- block 2 left it at — block 2 did not advance it).
        -- valid-count picks up by nframes; invalid unchanged.
        w3 @?= w2 + fromIntegral nframes
        i3 @?= i2

  , -- §6.C.4 follow-up: loop wrap. 4-frame buffer rendered for
    -- 12 samples with loop_flag=1; the kernel must wrap the
    -- write head and every sample is a valid write. Counter-
    -- confirmed.
    testCase "loop_flag=1 wraps the write head past the end" $ do
      let nframes = 12
          bufFrames = 4
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt bufFrames
        loadBuffer rt buf (replicate bufFrames 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w <- c_rt_graph_test_buffer_write_count          rt
        i <- c_rt_graph_test_buffer_invalid_write_count  rt
        w @?= fromIntegral nframes
        i @?= 0

  , -- §6.C.4 follow-up: one-shot end. Same 4-frame buffer,
    -- 12 samples, loop_flag=0. After frame 3 the head is past
    -- the end and every subsequent sample takes the invalid
    -- path. Counter-confirmed: bufFrames valid writes, the
    -- remainder invalid.
    testCase "loop_flag=0 stops writing past the buffer end" $ do
      let nframes = 12
          bufFrames = 4
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt bufFrames
        loadBuffer rt buf (replicate bufFrames 0.0)
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral nframes)
        w <- c_rt_graph_test_buffer_write_count          rt
        i <- c_rt_graph_test_buffer_invalid_write_count  rt
        w @?= fromIntegral bufFrames
        i @?= fromIntegral (nframes - bufFrames)

  , -- §6.C.4 follow-up: live set_control on slot 0 does NOT
    -- retarget the writer. Mirrors the §6.C.2 frozen-
    -- buffer-id regression test on the read side.
    testCase "live set_control on slot 0 does not retarget the writer" $ do
      let nframes = 16
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
          recIx =
            case [ rnIndex n
                 | tpl <- tgTemplates tg
                 , n   <- rgNodes (tplGraph tpl)
                 , rnKind n == KRecordBufMono
                 ] of
              [NodeIndex i] -> i
              other         -> error $
                "expected one RecordBufMono node, got " <> show other

      withRTGraph totalNodes nframes $ \rt -> do
        buf0 <- allocBuffer rt nframes
        buf1 <- allocBuffer rt nframes
        bufferId buf0 @?= 0
        bufferId buf1 @?= 1
        loadBuffer rt buf0 (replicate nframes 0.0)
        loadBuffer rt buf1 (replicate nframes 0.0)
        loadTemplateGraph rt tg

        -- Block 1: writer targets buffer 0 (the frozen id at
        -- instance reset).
        c_rt_graph_process rt (fromIntegral nframes)
        w1 <- c_rt_graph_test_buffer_write_count rt
        w1 @?= fromIntegral nframes

        -- Live-write controls[0] = 1.0 on the writer. A kernel
        -- that re-reads controls[0] per block would silently
        -- start writing buffer 1 from here onward. The §6.C.2
        -- contract pins the kernel to st->buffer_id, which is
        -- frozen at 0.
        c_rt_graph_instance_set_control rt 0
          (fromIntegral recIx) 0 (CDouble 1.0)

        c_rt_graph_process rt (fromIntegral nframes)
        w2 <- c_rt_graph_test_buffer_write_count rt
        i2 <- c_rt_graph_test_buffer_invalid_write_count rt
        -- Either (a) the writer kept writing buffer 0 — head
        -- continued past the end and stopped (loop_flag=0), so
        -- the second block's writes are all invalid; or (b) a
        -- regression would point the writer at buffer 1 which
        -- still has frames available, racking up nframes valid
        -- writes. The first nframes valid writes of block 1
        -- exactly filled buffer 0, so block 2 must be all
        -- invalid.
        w2 @?= w1
        i2 @?= fromIntegral nframes

  , -- §6.C.4 follow-up: same-buffer write from two templates is
    -- rejected at compileTemplateGraph time. This is the §6.C.4
    -- slice-4 diagnostic, now exercised end-to-end via the
    -- DSL builder (the existing slice-4 test used hand-built
    -- ResourceFootprints).
    testCase "same-buffer recordBufMono across templates is rejected" $ do
      let g1 = runSynth $ do
            _ <- recordBufMono (Buffer 3) (Param 0.25) (Param 0.0)
            pure ()
          g2 = runSynth $ do
            _ <- recordBufMono (Buffer 3) (Param 0.75) (Param 0.0)
            pure ()
      case compileTemplateGraph [("first", g1), ("second", g2)] of
        Right _ -> assertFailure
          "expected same-buffer BufWrite to be rejected end-to-end"
        Left err -> do
          assertBool
            ("diagnostic must mention 'buffer 3'; got: " <> err)
            ("buffer 3" `isInfixOf` err)
          assertBool
            ("diagnostic must mention 'first'; got: " <> err)
            ("first"  `isInfixOf` err)
          assertBool
            ("diagnostic must mention 'second'; got: " <> err)
            ("second" `isInfixOf` err)

  , -- §6.C.4 follow-up: scheduler barrier. A region with a
    -- writer must appear as a Barrier in segmentByBarrier's
    -- output, never inside a FreeSegment. Conservative
    -- serialization keeps the writer kernel from running in
    -- parallel with anything else.
    testCase "writer region is a scheduler Barrier, not a FreeSegment" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()
      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"

      let segments = segmentByBarrier rg
          writerInBarrier = any
            (\seg -> case seg of
                Barrier r ->
                  any (\nodeIx -> case [ rnKind n
                                       | n <- rgNodes rg
                                       , rnIndex n == nodeIx ] of
                                    [KRecordBufMono] -> True
                                    _                -> False)
                      (rrNodes r)
                FreeSegment _ -> False)
            segments
          writerInFreeSegment = any
            (\seg -> case seg of
                FreeSegment rs ->
                  any (\r -> any (\nodeIx ->
                                     case [ rnKind n
                                          | n <- rgNodes rg
                                          , rnIndex n == nodeIx ] of
                                       [KRecordBufMono] -> True
                                       _                -> False)
                                 (rrNodes r))
                      rs
                Barrier _ -> False)
            segments
      assertBool
        ("writer region must appear in a Barrier; segments = "
         <> show (length segments))
        writerInBarrier
      assertBool
        "writer region must never appear inside a FreeSegment"
        (not writerInFreeSegment)

  , -- §6.C.5 commit 1: a template whose footprint carries a
    -- BufWrite must be loaded with polyphony cap = 1. The auto-
    -- spawned instance at load time succeeds; any second
    -- c_rt_graph_template_instance_add for the same template
    -- must return -1 (cap reached, no voice stealing).
    testCase "writer template auto-spawn succeeds; second instance rejected" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      tg <- case compileTemplateGraph [("writer", writerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadTemplateGraph rt tg

        -- The auto-spawn already occupies slot 0; the live count
        -- for template 0 is therefore 1, matching the cap.
        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 commit 1: non-writer templates must keep the
    -- default polyphony (8). We don't peek at the cap directly
    -- (no FFI accessor) — instead we verify behavior: spawn
    -- multiple instances and confirm they all succeed.
    testCase "non-writer template keeps default polyphony behavior" $ do
      let readerGraph = runSynth $ do
            s <- sinOsc (Param 440.0) (Param 0.0)
            out 0 s

      tg <- case compileTemplateGraph [("reader", readerGraph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 32) 64 $ \rt -> do
        loadTemplateGraph rt tg
        -- Slot 0 is auto-spawned; spawning three more must
        -- succeed under the default cap of 8 (4 live total).
        s1 <- c_rt_graph_template_instance_add rt 0
        s2 <- c_rt_graph_template_instance_add rt 0
        s3 <- c_rt_graph_template_instance_add rt 0
        assertBool
          ("expected three additional non-writer instances; got "
           <> show [s1, s2, s3])
          (all (>= 0) [s1, s2, s3])

  , -- §6.C.5 commit 1: the clamp must apply when the writer
    -- template is registered as a *non-first* template too. The
    -- fused loader path shares the same clamping helper; this
    -- exercises it via a two-template mix.
    testCase "writer clamp survives non-first template position" $ do
      let readerGraph = runSynth $ do
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s
          writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 1.0)
            pure ()

      tg <- case compileTemplateGraph
                   [ ("reader", readerGraph)
                   , ("writer", writerGraph) ] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"

      -- After §6.C.4 topo-sort the writer must be first in
      -- execution order, so on the C side template_id 0 is the
      -- writer and template_id 1 is the reader.
      let names = map tplName (tgTemplates tg)
      assertEqual "writer must precede reader after topo-sort"
        ["writer", "reader"] names

      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))

      withRTGraph (totalNodes + 16) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadTemplateGraph rt tg

        -- Writer is template 0; second spawn must be rejected.
        writerExtra <- c_rt_graph_template_instance_add rt 0
        writerExtra @?= (-1)
        -- Reader is template 1; second spawn must succeed under
        -- the default cap.
        readerExtra <- c_rt_graph_template_instance_add rt 1
        assertBool
          ("reader second-instance spawn must succeed; got "
           <> show readerExtra)
          (readerExtra >= 0)

  , -- §6.C.5 commit 2: two writer nodes against the same buffer
    -- in one SynthGraph must be rejected by validation. The
    -- diagnostic names the offending buffer id so authors can
    -- locate the conflict instead of chasing a downstream
    -- topology error.
    testCase "duplicate same-buffer writers in one graph are rejected" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 2) (Param 0.25) (Param 0.0)
            _ <- recordBufMono (Buffer 2) (Param 0.75) (Param 0.0)
            pure ()
      case lowerGraph g of
        Right _ -> assertFailure
          "expected duplicate BufWrite on buffer 2 to be rejected"
        Left err ->
          assertBool
            ("diagnostic must mention 'buffer 2'; got: " <> err)
            ("buffer 2" `isInfixOf` err)

  , -- §6.C.5 commit 2: writers targeting *different* buffers
    -- compose freely. The rule is per-buffer, not per-graph.
    testCase "writers to different buffers in one graph are accepted" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.25) (Param 0.0)
            _ <- recordBufMono (Buffer 1) (Param 0.75) (Param 0.0)
            pure ()
      case lowerGraph g of
        Right _  -> pure ()
        Left err -> assertFailure $
          "writers to different buffers must lower cleanly; got: "
          <> err

  , -- §6.C.5 commit 2: writer + reader on the same buffer is
    -- the canonical compose case. The E_r edge pins the
    -- writer before the reader; nothing about that pattern is
    -- ambiguous.
    testCase "writer + reader on same buffer in one graph is accepted" $ do
      let g = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            s <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            out 0 s
      case lowerGraph g of
        Right _  -> pure ()
        Left err -> assertFailure $
          "writer + reader on same buffer must lower cleanly; got: "
          <> err

  , -- §6.C.5 follow-up: loadRuntimeGraph (single-template
    -- loader, used by the legacy ABI and by app/Main.hs's demo
    -- helpers) must clamp writer-template polyphony to 1 the
    -- same way the multi-template loader does. The runtime
    -- backstop in rt_graph.cpp catches direct-C-ABI callers;
    -- this test pins the Haskell loader's declarative clamp.
    testCase "loadRuntimeGraph clamps a writer graph's polyphony" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadRuntimeGraph rt rg

        -- Auto-spawn took slot 0; second spawn must hit the cap.
        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 follow-up: loadRuntimeGraphFused mirrors the
    -- unfused loader. Even though the demo graph here has no
    -- RFused inputs, the loader must still apply the clamp on
    -- the same writer-presence rule.
    testCase "loadRuntimeGraphFused clamps a writer graph's polyphony" $ do
      let writerGraph = runSynth $ do
            _ <- recordBufMono (Buffer 0) (Param 0.5) (Param 0.0)
            pure ()

      rg <- case lowerGraph writerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 8) 64 $ \rt -> do
        _ <- allocBuffer rt 64
        loadRuntimeGraphFused rt rg

        extra <- c_rt_graph_template_instance_add rt 0
        extra @?= (-1)

  , -- §6.C.5 follow-up: a non-writer graph loaded via
    -- loadRuntimeGraph must keep its default polyphony (8) —
    -- the clamp is gated on the writer-presence check.
    testCase "loadRuntimeGraph leaves non-writer polyphony untouched" $ do
      let readerGraph = runSynth $ do
            s <- sinOsc (Param 440.0) (Param 0.0)
            out 0 s

      rg <- case lowerGraph readerGraph >>= compileRuntimeGraph of
        Right r  -> pure r
        Left err -> assertFailure err >> error "unreachable"

      withRTGraph (length (rgNodes rg) + 32) 64 $ \rt -> do
        loadRuntimeGraph rt rg
        -- Slot 0 is auto-spawned; spawning three more must
        -- succeed under the default cap of 8.
        s1 <- c_rt_graph_template_instance_add rt 0
        s2 <- c_rt_graph_template_instance_add rt 0
        s3 <- c_rt_graph_template_instance_add rt 0
        assertBool
          ("expected three additional non-writer instances; got "
           <> show [s1, s2, s3])
          (all (>= 0) [s1, s2, s3])
  ]

------------------------------------------------------------
-- §6.D slice 1: KSpectralFreeze surface + C++ skeleton
--
-- Slice-1 tests pin only the Haskell-side shape and the
-- declared latency. No kernel-output assertions yet — the
-- C++ side is a stub that emits silence. Slice 2 adds the
-- real STFT body + pre-roll silence + warmed-up impulse +
-- sine reconstruction; slice 3 adds the freeze gate tests.
--
-- Property tests in 'unitTests' iterate over every
-- 'NodeKind' (kindTag-vs-kind_supported, ugenView arities,
-- portInfo coverage) and therefore extend through
-- 'KSpectralFreeze' automatically — slice 1 inherits that
-- coverage without writing a new test.
------------------------------------------------------------

spectralFreezeSkeletonTests :: TestTree
spectralFreezeSkeletonTests =
  testGroup "Phase 6.D slice 1: SpectralFreeze surface"
  [ testCase "inferEff produces Pure" $ do
      -- §6.D: spectral kinds own their windowing state per
      -- instance, nothing crosses a graph boundary. Pinning
      -- this means a future spectrum-streaming kind that
      -- needs a real Eff axis is forced to introduce it
      -- deliberately rather than fall through the default.
      let g = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          freezeEffs =
            [ eff
            | n   <- giNodes ir
            , eff <- irEffects n
            , irKind n == KSpectralFreeze
            ]
      freezeEffs @?= [Pure]

  , testCase "kindSpec / portInfo / kindLatency agree on shape" $ do
      ksTag          (kindSpec KSpectralFreeze) @?= 22
      ksRate         (kindSpec KSpectralFreeze) @?= SampleRate
      ksAudioArity   (kindSpec KSpectralFreeze) @?= 2
      ksControlArity (kindSpec KSpectralFreeze) @?= 2
      ksLabel        (kindSpec KSpectralFreeze) @?= "spectralFreeze"
      portInfo KSpectralFreeze (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "signal_in")
      portInfo KSpectralFreeze (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "freeze_flag")
      portInfo KSpectralFreeze (PortIndex 2) @?= Nothing

  , testCase "kindLatency declares N=1024 for KSpectralFreeze" $ do
      kindLatency KSpectralFreeze @?= Just 1024
      -- Everything else must stay Nothing — the accessor is
      -- only meaningful on kinds that introduce inherent
      -- pipeline latency.
      kindLatency KSinOsc         @?= Nothing
      kindLatency KGain           @?= Nothing
      kindLatency KLPF            @?= Nothing
      kindLatency KPlayBufMono    @?= Nothing
      kindLatency KRecordBufMono  @?= Nothing

  , testCase "latency footprint reports SpectralFreeze and propagates downstream" $ do
      let graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            shaped <- gain frozen (Param 0.5)
            out 0 shaped
      rg <- case lowerGraph graph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"
      let footprint = declaredLatencyFootprint rg
          lats      = nodeOutputLatencies rg
          latsFor k =
            [ lat
            | n <- rgNodes rg
            , rnKind n == k
            , Just lat <- [M.lookup (rnIndex n) lats]
            ]
      case footprint of
        [DeclaredNodeLatency _ KSpectralFreeze 1024] -> pure ()
        other ->
          assertFailure $
            "expected one KSpectralFreeze declared-latency row, got "
            <> show other
      latsFor KSpectralFreeze @?= [1024]
      latsFor KGain           @?= [1024]
      latsFor KOut            @?= [1024]
      inputLatencySkews rg    @?= []

  , testCase "latency skew reports uncompensated dry/wet spectral path" $ do
      let graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            mixed  <- add src frozen
            out 0 mixed
      rg <- case lowerGraph graph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"
      let skews = inputLatencySkews rg
          lats  = nodeOutputLatencies rg
          latsFor k =
            [ lat
            | n <- rgNodes rg
            , rnKind n == k
            , Just lat <- [M.lookup (rnIndex n) lats]
            ]
      case [s | s <- skews, lsKind s == KAdd] of
        [s] -> do
          lsMinLatency s @?= 0
          lsMaxLatency s @?= 1024
          sort (map ilLatency (lsInputs s)) @?= [0, 1024]
        other ->
          assertFailure $
            "expected one KAdd latency-skew diagnostic, got "
            <> show other
      latsFor KAdd @?= [1024]
      latsFor KOut @?= [1024]

  , testCase "ugenView arities match kindSpec for SpectralFreeze" $ do
      -- The local check that the global property
      -- 'ugenView arities match kindSpec for every UGen'
      -- already covers — but a focused unit case here makes
      -- intent obvious for reviewers reading slice 1 in
      -- isolation.
      let view = ugenView
            (SpectralFreeze (Param 0.0) (Param 0.0))
      length (uvInputs view)   @?= 2
      length (uvControls view) @?= 2

  , testCase "spectralFreeze graph compiles and renders without crashing" $ do
      -- Stub-era smoke test, retained for the slice-1
      -- invariant: the kind loads, dispatches, and a
      -- process_graph call returns normally. Slice 2 adds
      -- the kernel-correctness assertions below.
      let nframes = 64
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

  -- ----------------------------------------------------------
  -- §6.D slice 2: real STFT pass-through, counters, Barrier
  --
  -- All tests below run with N=1024 / hop=256 — the constants
  -- baked into 'SpectralFreezeState'. If those constants change
  -- the test expectations have to follow.
  -- ----------------------------------------------------------

  , testCase "pre-roll is silent below numerical noise" $ do
      -- Frames 0..N-1 of the output are zero by construction:
      -- no analysis hops have fired yet (the first hop boundary
      -- is at samples_in == N), so the output ring is the
      -- value-initialized zero buffer.
      let nframes = 1024  -- exactly N
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              peak = maximum (map abs rcvs)
          assertBool
            ("pre-roll must be silent (peak < 1e-3); got "
             <> show peak)
            (peak < 1.0e-3)

  , testCase "counter math: analysis and resynthesis tick on every hop in pass-through" $ do
      -- Render exactly 4N frames. After 4*1024 samples_in
      -- counter, the analysis condition (samples_in % hop == 0
      -- AND samples_in >= N) fires at samples_in =
      -- N, N+hop, N+2*hop, ..., 4N. That gives floor((4N - N)
      -- / hop) + 1 = floor(3*1024 / 256) + 1 = 13 hops. Both
      -- counters tick once per hop in pass-through.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis  <- c_rt_graph_test_spectral_analysis_count    rt
        resynth   <- c_rt_graph_test_spectral_resynthesis_count rt
        let expected = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= expected
        resynth  @?= expected

  , testCase "warmed-up impulse emerges N samples after injection" $ do
      -- Feed 2N silent frames, then an impulse at frame 2N,
      -- through spectralFreeze in pass-through mode. The
      -- impulse must emerge ~N samples after injection — at
      -- the response peak — proving the declared kindLatency
      -- of 1024. Frame-0 injection is *not* used: with causal
      -- startup the first analysis window's edge is at frame
      -- 0 where the Hann weight is zero and no overlapping
      -- pre-roll contributes, so an impulse there would be
      -- attenuated by alignment rather than latency
      -- (§2.3 of the 6.D design note).
      --
      -- Drive the input from playBufMono reading a 4N-frame
      -- buffer with a single non-zero sample at frame 2N. The
      -- buffer is the only way the DSL can express a
      -- one-shot time-positioned signal without adding new
      -- generators.
      let n        = 1024 :: Int
          totalF   = 4 * n
          impulseF = 2 * n         -- inject at frame 2N
          nframes  = totalF
          graph = runSynth $ do
            sig    <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            frozen <- spectralFreeze sig (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt totalF
        bufferId buf @?= 0
        -- Build the impulse: silence everywhere, 1.0 at
        -- frame 2N.
        let impulseFrames =
              [ if i == impulseF then 1.0 else 0.0
              | i <- [0 .. totalF - 1]
              ]
        loadBuffer rt buf impulseFrames
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              -- Locate the global peak position in the
              -- output. With N-sample steady-state latency,
              -- the impulse's energy is spread by Hann
              -- windowing but peaks ~N samples after
              -- injection.
              indexed = zip [0 :: Int ..] (map abs rcvs)
              (peakIdx, peakAmp) =
                foldr (\p@(_, a) q@(_, b) -> if a > b then p else q)
                      (0, 0) indexed
              expectedPeak = impulseF + n
              tolerance    = 16 :: Int  -- a single hop
          assertBool
            ("output must have non-trivial energy; peak amp = "
             <> show peakAmp)
            (peakAmp > 1.0e-3)
          assertBool
            ("impulse peak must land near frame " <> show expectedPeak
             <> " (= injection " <> show impulseF
             <> " + latency " <> show n <> "); observed peak at frame "
             <> show peakIdx)
            (abs (peakIdx - expectedPeak) <= tolerance)

  , testCase "pass-through reconstructs a 440 Hz sine in steady state" $ do
      -- Render 4N frames of a 440 Hz sine, skip the first 2N
      -- (pre-roll + warmup), and assert the steady-state peak
      -- amplitude is within 5% of 1.0. WOLA normalization
      -- targets unity gain; the 5% tolerance covers the
      -- Hann-window contribution sum that doesn't quite
      -- reach exact COLA at hop = N/4 (the analytic value
      -- for the chosen overlap is ~1.5 / 1.5 = 1.0, and
      -- numerical rounding in the FFT roundtrip plus the
      -- N-truncated window cosine series adds <1% in
      -- practice).
      let n       = 1024 :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs       = map (\(CFloat x) -> x) rendered
              steady     = drop (2 * n) rcvs
              steadyPeak = maximum (map abs steady)
          assertBool
            ("steady-state pass-through must reach unity (±5%); "
             <> "peak = " <> show steadyPeak)
            (steadyPeak > 0.95 && steadyPeak < 1.05)

  , testCase "spectral region is a scheduler Barrier" $ do
      -- regionHasSpectral makes any region containing a
      -- KSpectralFreeze node a Barrier. The spectral kernel
      -- never runs in a FreeSegment.
      let graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      rg <- case lowerGraph graph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"
      let segments = segmentByBarrier rg
          regionHasFreezeKind r =
            any (\nodeIx -> case [ rnKind n
                                 | n <- rgNodes rg
                                 , rnIndex n == nodeIx ] of
                              [KSpectralFreeze] -> True
                              _                 -> False)
                (rrNodes r)
          freezeInBarrier = any
            (\seg -> case seg of
                Barrier r     -> regionHasFreezeKind r
                FreeSegment _ -> False)
            segments
          freezeInFree = any
            (\seg -> case seg of
                FreeSegment rs -> any regionHasFreezeKind rs
                Barrier _      -> False)
            segments
      assertBool
        ("spectral region must appear in a Barrier; segments = "
         <> show (length segments))
        freezeInBarrier
      assertBool
        "spectral region must never appear inside a FreeSegment"
        (not freezeInFree)

  -- ----------------------------------------------------------
  -- §6.D slice 3: freeze gate
  --
  -- Slice 3 wires the freeze_flag input into the kernel. At
  -- each hop boundary the kernel hop-latches the flag and
  -- selects between pass-through (analyze + persist + IFFT)
  -- and freeze (skip analysis, reconstruct from stored
  -- Hermitian half + IFFT). The two counters diverge in
  -- freeze mode (analysis stops; resynthesis continues).
  -- ----------------------------------------------------------

  , testCase "freeze halts analysis but continues resynthesis" $ do
      -- Render 8N frames with freeze_flag stuck at 1 from
      -- the start (Param 1.0). The first hop fires at
      -- samples_in = N; since freeze_valid is false (no
      -- analysis ever ran), the kernel emits silence
      -- through IFFT. analysis_count stays at 0; the
      -- resynthesis counter ticks once per hop.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 8 * n
          nframes = totalF
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 1.0)  -- freeze=on from start
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis <- c_rt_graph_test_spectral_analysis_count    rt
        resynth  <- c_rt_graph_test_spectral_resynthesis_count rt
        let expectedResynth = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= 0
        resynth  @?= expectedResynth

  , testCase "freeze mode sustains the frozen content after the input goes silent" $ do
      -- The strict freeze-sustain test: input must genuinely
      -- go silent during the freeze window so the test
      -- proves the *frozen spectrum* keeps producing output
      -- (not just that the analysis kept running but the
      -- counter happens to not advance).
      --
      -- Drive signal_in from playBufMono on a precomputed
      -- buffer: frames1 of 440 Hz sine, then frames2 of
      -- zeros. Block 1 (frames1 long) runs in pass-through,
      -- analyzing the sine and persisting the spectrum.
      -- Then we set freeze_default = 1.0 live; block 2
      -- (frames2 long) reads zeros from the buffer's tail —
      -- so signal_in is honestly silent — and the only way
      -- the output stays non-trivial is if the kernel keeps
      -- emitting the frozen spectrum.
      let n        = 1024 :: Int
          frames1  = 4 * n
          frames2  = 2 * n
          totalF   = frames1 + frames2
          -- Sample rate is wired into the C++ side (48000);
          -- the exact phase doesn't matter for this test as
          -- long as the buffer carries a real 440 Hz tone
          -- through frames 0..frames1-1.
          sr       = 48000 :: Double
          freq     = 440   :: Double
          sineSamples =
            [ realToFrac
                (sin (2 * pi * freq * fromIntegral i / sr))
              :: Float
            | i <- [0 .. frames1 - 1]
            ]
          silenceTail = replicate frames2 (0.0 :: Float)
          bufContents = sineSamples ++ silenceTail
          graph = runSynth $ do
            -- One-shot playback: rate=1.0, start_frame=0,
            -- loop=0. After the buffer is exhausted (which
            -- it is partway through block 2) playBufMono
            -- emits zeros — also genuinely silent.
            src <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            -- Wire freeze_in to a constant; flip the live
            -- control between blocks.
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph (totalNodes + 8) (max frames1 frames2) $ \rt -> do
        buf <- allocBuffer rt totalF
        bufferId buf @?= 0
        loadBuffer rt buf bufContents
        loadTemplateGraph rt tg

        -- Block 1: pass-through. The kernel sees the sine,
        -- records spectra at each hop.
        c_rt_graph_process rt (fromIntegral frames1)
        analysis1 <- c_rt_graph_test_spectral_analysis_count rt
        assertBool
          ("block 1 must record some analyses; got "
           <> show analysis1)
          (analysis1 > 0)

        -- Flip freeze on. spectralFreeze is the second node
        -- in the topo order (playBufMono = 0, spectralFreeze
        -- = 1, out = 2); controls[1] is the freeze_default
        -- that the kernel falls back on when freeze_in is
        -- empty (Param 0.0 means no wired RFrom source).
        c_rt_graph_instance_set_control rt 0 1 1 1.0

        -- Block 2: input is now silent (buffer exhausted +
        -- buffer tail is zeros, both render to 0.0 on
        -- signal_in). The frozen spectrum is the only thing
        -- left contributing to the output.
        c_rt_graph_process rt (fromIntegral frames2)
        analysis2 <- c_rt_graph_test_spectral_analysis_count rt
        -- Analysis_count must not advance during freeze.
        analysis2 @?= analysis1

        allocaBytes (frames2 * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral frames2) (castPtr bp)
          rendered <- peekArray frames2 (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              peak = maximum (map abs rcvs)
          assertBool
            ("frozen output must keep producing the recorded "
             <> "sine after signal_in goes silent; peak = "
             <> show peak)
            (peak > 0.1)

  , testCase "hop-boundary latch: freeze_flag read happens at the hop's fi" $ do
      -- §6.D hardening: prove the kernel hop-latches the
      -- freeze_flag at exactly fi = hop boundary, not at
      -- block-start, block-end, or a sample-rounded
      -- approximation. The kernel reads
      -- @freeze_in[fi]@ where @fi@ is the loop index at the
      -- moment a hop fires. With N=1024 / hop=256 the first
      -- three hops fire at fi=1023, 1279, 1535 (samples_in
      -- crosses 1024 / 1280 / 1536). If we vary the freeze
      -- transition by a single frame around fi=1279, the
      -- expected analysis_count flips because the hop-1
      -- decision flips.
      --
      -- Two sub-scenarios, each in its own RT graph:
      --
      --   transition = 1279 → freeze_in[1279] = 1 → hop 1
      --     freezes → analysis_count = 1 (only hop 0).
      --
      --   transition = 1280 → freeze_in[1279] = 0 → hop 1
      --     analyzes; hop 2 (fi=1535) reads
      --     freeze_in[1535] = 1 → freezes →
      --     analysis_count = 2.
      --
      -- The 1-frame difference between the two scenarios is
      -- the proof: the latch lands at exactly the hop's fi,
      -- not anywhere else.
      let n         = 1024 :: Int
          hop       = 256  :: Int
          nframes   = n + 2 * hop          -- 1536: covers hops at fi=1023, 1279, 1535
          freezeBuf transitionF =
            [ if i >= transitionF then 1.0 else 0.0 :: Float
            | i <- [0 .. nframes - 1]
            ]
          -- Two separate audio buffers: buffer 0 is the
          -- signal_in source (silent sine — content doesn't
          -- matter, only the freeze_flag does), buffer 1 is
          -- the freeze_flag transition.
          graph = runSynth $ do
            -- A signal source for spectralFreeze. The
            -- content doesn't change the analysis_count
            -- assertion — we're testing the freeze gate
            -- only. Use a sinOsc so the kernel has real
            -- audio to analyze on pass-through hops.
            sig <- sinOsc 440.0 0.0
            -- The freeze_flag, driven from playBufMono on a
            -- buffer whose values transition mid-render.
            fl  <- playBufMono (Buffer 1) (Param 1.0) (Param 0) (Param 0)
            frozen <- spectralFreeze sig fl
            out 0 frozen

          runWithTransition transitionF expectedAnalysis = do
            tg <- case compileTemplateGraph
                         [("freeze", graph)] of
              Right t  -> pure t
              Left err -> assertFailure err >> error "unreachable"
            let totalNodes =
                  sum (map (length . rgNodes . tplGraph)
                           (tgTemplates tg))
            withRTGraph (totalNodes + 8) nframes $ \rt -> do
              -- Buffer 0 reserved for the signal — left
              -- unallocated since signal_in is wired from
              -- sinOsc, not a buffer. Buffer 1 holds the
              -- freeze transition pattern.
              _    <- allocBuffer rt 4  -- placeholder so buf 1 lands as id 1
              fbuf <- allocBuffer rt nframes
              bufferId fbuf @?= 1
              loadBuffer rt fbuf (freezeBuf transitionF)
              loadTemplateGraph rt tg
              c_rt_graph_process rt (fromIntegral nframes)
              analysis <- c_rt_graph_test_spectral_analysis_count rt
              assertEqual
                ("transition at fi=" <> show transitionF
                 <> " must produce analysis_count = "
                 <> show expectedAnalysis)
                expectedAnalysis analysis

      runWithTransition 1279 1
      runWithTransition 1280 2

  , testCase "unfreeze recovery: analysis resumes after the flag drops" $ do
      -- Three blocks: pass-through, freeze, then unfreeze.
      -- Each phase verifies its own counter contract:
      -- block 1 advances analysis, block 2 freezes it,
      -- block 3 advances analysis again.
      let n       = 1024 :: Int
          phase   = 4 * n
          nframes = phase
          graph = runSynth $ do
            src    <- sinOsc 440.0 0.0
            frozen <- spectralFreeze src (Param 0.0)
            out 0 frozen
      tg <- case compileTemplateGraph [("freeze", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph (totalNodes + 8) nframes $ \rt -> do
        loadTemplateGraph rt tg

        c_rt_graph_process rt (fromIntegral phase)
        a1 <- c_rt_graph_test_spectral_analysis_count rt

        c_rt_graph_instance_set_control rt 0 1 1 1.0   -- freeze on
        c_rt_graph_process rt (fromIntegral phase)
        a2 <- c_rt_graph_test_spectral_analysis_count rt
        a2 @?= a1                                       -- analysis paused

        c_rt_graph_instance_set_control rt 0 1 1 0.0   -- freeze off
        c_rt_graph_process rt (fromIntegral phase)
        a3 <- c_rt_graph_test_spectral_analysis_count rt
        assertBool
          ("analysis must resume after unfreeze; "
           <> "a1=" <> show a1 <> " a2=" <> show a2
           <> " a3=" <> show a3)
          (a3 > a2)
  ]

spectralLpfTests :: TestTree
spectralLpfTests =
  testGroup "Phase 6.D second spectral kind: SpectralLpf surface"
  [ testCase "inferEff produces Pure" $ do
      -- §6.D: spectral kinds (both freeze and lpf) own their
      -- windowing state per instance, nothing crosses a graph
      -- boundary. The lpf row must stay Pure for the same
      -- reason as freeze.
      let g = runSynth $ do
            src      <- sinOsc 440.0 0.0
            filtered <- spectralLpf src (Param 1000.0)
            out 0 filtered
          ir = case lowerGraph g of
                 Right ir' -> ir'
                 Left err  -> error err
          lpfEffs =
            [ eff
            | n   <- giNodes ir
            , eff <- irEffects n
            , irKind n == KSpectralLpf
            ]
      lpfEffs @?= [Pure]

  , testCase "kindSpec / portInfo / kindLatency agree on shape" $ do
      ksTag          (kindSpec KSpectralLpf) @?= 24
      ksRate         (kindSpec KSpectralLpf) @?= SampleRate
      ksAudioArity   (kindSpec KSpectralLpf) @?= 2
      ksControlArity (kindSpec KSpectralLpf) @?= 2
      ksLabel        (kindSpec KSpectralLpf) @?= "spectralLpf"
      portInfo KSpectralLpf (PortIndex 0)
        @?= Just (PortInfo PortSampleAccurate "signal_in")
      portInfo KSpectralLpf (PortIndex 1)
        @?= Just (PortInfo PortSampleAccurate "cutoff_hz")
      portInfo KSpectralLpf (PortIndex 2) @?= Nothing

  , testCase "kindLatency declares N=1024 for KSpectralLpf" $ do
      kindLatency KSpectralLpf    @?= Just 1024
      -- Freeze continues to declare the same latency; this is
      -- a regression guard for the shared latency contract.
      kindLatency KSpectralFreeze @?= Just 1024

  , testCase "ugenView arities match kindSpec for SpectralLpf" $ do
      let view = ugenView
            (SpectralLpf (Param 0.0) (Param 1000.0))
      length (uvInputs view)   @?= 2
      length (uvControls view) @?= 2

  , testCase "spectralLpf graph compiles and renders without crashing" $ do
      let nframes = 64
          graph = runSynth $ do
            src      <- sinOsc 440.0 0.0
            filtered <- spectralLpf src (Param 1000.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)

  , testCase "pre-roll is silent below numerical noise" $ do
      -- Same pre-roll contract as freeze: frames 0..N-1 are
      -- value-initialized zero because no analysis hop has
      -- fired yet. Independent of the cutoff.
      let nframes = 1024
          graph = runSynth $ do
            src      <- sinOsc 440.0 0.0
            filtered <- spectralLpf src (Param 4000.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              peak = maximum (map abs rcvs)
          assertBool
            ("pre-roll must be silent (peak < 1e-3); got "
             <> show peak)
            (peak < 1.0e-3)

  , testCase "counter math: analysis and resynthesis tick on every hop" $ do
      -- Mirror of the freeze counter-math test. LPF always
      -- runs analysis (no freeze gate), so both counters
      -- advance once per hop in lockstep.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src      <- sinOsc 440.0 0.0
            filtered <- spectralLpf src (Param 4000.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis <- c_rt_graph_test_spectral_lpf_analysis_count    rt
        resynth  <- c_rt_graph_test_spectral_lpf_resynthesis_count rt
        let expected = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= expected
        resynth  @?= expected
        -- Freeze counters must stay at zero — no contamination
        -- across kinds.
        fa <- c_rt_graph_test_spectral_analysis_count    rt
        fr <- c_rt_graph_test_spectral_resynthesis_count rt
        fa @?= 0
        fr @?= 0

  , testCase "warmed-up impulse at cutoff = SR/2 emerges N samples after injection (Nyquist no-op)" $ do
      -- Set cutoff = Nyquist (SR/2 = 24000 Hz at the runtime
      -- sample rate). The bin-mask range is empty
      -- (cutoff_bin = N/2 means the loop runs from N/2+1 to
      -- N/2-1, which is empty). The kernel becomes a true
      -- pass-through modulo windowing — same shape as freeze
      -- pass-through, including the N-sample latency.
      let n        = 1024 :: Int
          totalF   = 4 * n
          impulseF = 2 * n
          nframes  = totalF
          graph = runSynth $ do
            sig      <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            filtered <- spectralLpf sig (Param 24000.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt totalF
        bufferId buf @?= 0
        let impulseFrames =
              [ if i == impulseF then 1.0 else 0.0
              | i <- [0 .. totalF - 1]
              ]
        loadBuffer rt buf impulseFrames
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs = map (\(CFloat x) -> x) rendered
              indexed = zip [0 :: Int ..] (map abs rcvs)
              (peakIdx, peakAmp) =
                foldr (\p@(_, a) q@(_, b) -> if a > b then p else q)
                      (0, 0) indexed
              expectedPeak = impulseF + n
              tolerance    = 16 :: Int
          assertBool
            ("Nyquist-cutoff output must carry the impulse; peak amp = "
             <> show peakAmp)
            (peakAmp > 1.0e-3)
          assertBool
            ("Nyquist-cutoff impulse peak must land near frame "
             <> show expectedPeak <> "; observed peak at frame "
             <> show peakIdx)
            (abs (peakIdx - expectedPeak) <= tolerance)

  , testCase "pass-band: warmed-up sine well below cutoff passes within numerical noise" $ do
      -- 110 Hz sine, cutoff = 4 kHz. At SR=48 kHz / N=1024:
      -- bin(110)  = round(110*1024/48000)  = 2
      -- bin(4000) = round(4000*1024/48000) = 85
      -- Bin 2 is well below the mask boundary, so the lpf is a
      -- no-op modulo windowing and the steady-state amplitude
      -- recovers unity, same tolerance as the freeze
      -- pass-through reconstruction test.
      let n       = 1024 :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src      <- sinOsc 110.0 0.0
            filtered <- spectralLpf src (Param 4000.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs       = map (\(CFloat x) -> x) rendered
              steady     = drop (2 * n) rcvs
              steadyPeak = maximum (map abs steady)
          assertBool
            ("pass-band sine must reach unity (±5%); peak = "
             <> show steadyPeak)
            (steadyPeak > 0.95 && steadyPeak < 1.05)

  , testCase "stop-band: warmed-up sine well above cutoff is attenuated" $ do
      -- 4 kHz sine, cutoff = 500 Hz. At SR=48 kHz / N=1024:
      -- bin(4000) = 85
      -- bin(500)  = round(500*1024/48000) = 11
      -- Bin 85 sits inside the masked range, so the kernel
      -- zeroes the analyzed-bin's contribution before IFFT
      -- and the steady-state output drops below 1e-2.
      let n       = 1024 :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            src      <- sinOsc 4000.0 0.0
            filtered <- spectralLpf src (Param 500.0)
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        allocaBytes (nframes * 4) $ \bp -> do
          _ <- c_rt_graph_read_bus rt 0
                 (fromIntegral nframes) (castPtr bp)
          rendered <- peekArray nframes (bp :: PtrCFloat)
          let rcvs       = map (\(CFloat x) -> x) rendered
              steady     = drop (2 * n) rcvs
              steadyPeak = maximum (map abs steady)
          assertBool
            ("stop-band sine must be attenuated below 1e-2; peak = "
             <> show steadyPeak)
            (steadyPeak < 1.0e-2)

  , testCase "cutoff is hop-latched (no mid-hop FFT runs on sub-hop control change)" $ do
      -- The contract is: the kernel runs analysis exactly once
      -- per hop, regardless of how the cutoff_hz buffer varies
      -- within a hop. Run a single hop's worth of frames with
      -- a cutoff buffer that toggles every sample, then assert
      -- spectral_lpf_analysis_count advanced exactly by the
      -- expected hop math — not once per cutoff change.
      let n         = 1024 :: Int
          hop       = 256  :: Int
          totalF    = n + 2 * hop      -- hops at samples_in = 1024, 1280, 1536
          nframes   = totalF
          -- Cutoff toggles every frame between 4000 Hz and 50 Hz.
          -- If the kernel re-read cutoff_hz per sample and
          -- ran FFTs accordingly, the counter would explode;
          -- with hop-latching it must equal floor((totalF -
          -- N) / hop) + 1 = 3.
          toggleBuf =
            [ if odd i then 50.0 else 4000.0
            | i <- [0 .. nframes - 1]
            ]
          graph = runSynth $ do
            sig      <- sinOsc 440.0 0.0
            cf       <- playBufMono (Buffer 0) (Param 1.0) (Param 0) (Param 0)
            filtered <- spectralLpf sig cf
            out 0 filtered
      tg <- case compileTemplateGraph [("lpf", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        buf <- allocBuffer rt nframes
        bufferId buf @?= 0
        loadBuffer rt buf toggleBuf
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        analysis <- c_rt_graph_test_spectral_lpf_analysis_count rt
        let expected = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        analysis @?= expected

  , testCase "spectral region is a scheduler Barrier" $ do
      let graph = runSynth $ do
            src      <- sinOsc 440.0 0.0
            filtered <- spectralLpf src (Param 4000.0)
            out 0 filtered
      rg <- case lowerGraph graph >>= compileRuntimeGraph of
              Right r  -> pure r
              Left err -> assertFailure err >> error "unreachable"
      let segments = segmentByBarrier rg
          regionHasLpfKind r =
            any (\nodeIx -> case [ rnKind n
                                 | n <- rgNodes rg
                                 , rnIndex n == nodeIx ] of
                              [KSpectralLpf] -> True
                              _              -> False)
                (rrNodes r)
          lpfInBarrier = any
            (\seg -> case seg of
                Barrier r     -> regionHasLpfKind r
                FreeSegment _ -> False)
            segments
          lpfInFree = any
            (\seg -> case seg of
                FreeSegment rs -> any regionHasLpfKind rs
                Barrier _      -> False)
            segments
      assertBool
        ("spectral lpf region must appear in a Barrier; segments = "
         <> show (length segments))
        lpfInBarrier
      assertBool
        "spectral lpf region must never appear inside a FreeSegment"
        (not lpfInFree)

  , testCase "shared-helper smoke: freeze and lpf coexist on disjoint voices" $ do
      -- A graph carrying both spectral kinds. Renders enough
      -- frames for both to advance their counter pairs
      -- independently — if the §6.D slice 1 shared helper had
      -- accidentally aliased state between kinds, one of the
      -- counter pairs would either stay at zero or advance
      -- twice.
      let n       = 1024 :: Int
          hop     = 256  :: Int
          totalF  = 4 * n
          nframes = totalF
          graph = runSynth $ do
            srcA   <- sinOsc 220.0 0.0
            srcB   <- sawOsc 110.0 0.0
            frozen <- spectralFreeze srcA (Param 0.0)
            lpfed  <- spectralLpf    srcB (Param 4000.0)
            mixed  <- add frozen lpfed
            out 0 mixed
      tg <- case compileTemplateGraph [("dual", graph)] of
        Right t  -> pure t
        Left err -> assertFailure err >> error "unreachable"
      let totalNodes =
            sum (map (length . rgNodes . tplGraph) (tgTemplates tg))
      withRTGraph totalNodes nframes $ \rt -> do
        loadTemplateGraph rt tg
        c_rt_graph_process rt (fromIntegral nframes)
        let expected = fromIntegral
              ((totalF - n) `div` hop + 1) :: CLLong
        fa <- c_rt_graph_test_spectral_analysis_count    rt
        fr <- c_rt_graph_test_spectral_resynthesis_count rt
        la <- c_rt_graph_test_spectral_lpf_analysis_count    rt
        lr <- c_rt_graph_test_spectral_lpf_resynthesis_count rt
        fa @?= expected
        fr @?= expected
        la @?= expected
        lr @?= expected
  ]
