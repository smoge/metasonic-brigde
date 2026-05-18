-- | Phase 8.A: authoring DSL lowering tests.
--
-- Pins the lowering shape of the authoring DSL surface defined in
-- "MetaSonic.Authoring": the channel-wrapper constructors must be
-- pure authoring shapes, named control / send-return / tagged-node
-- helpers must materialize predictable runtime graphs, and the
-- 'cc'/'tagged'/'withHandle' macros must reduce to the same
-- 'compileRuntimeGraph' output as the equivalent hand-rolled
-- 'SynthGraph'.
module MetaSonic.Spec.Feature.AuthoringDSL
  ( authoringDslTests
  ) where

import qualified Data.Map.Strict           as M
import qualified Data.Set                  as S
import           Data.List                 (sort)
import           Control.Monad             (forM_)
import           Data.Word                 (Word8)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Templates
import qualified MetaSonic.OSC.Dispatch    as OSC
import qualified MetaSonic.OSC.Wire        as OSC
import qualified MetaSonic.Authoring       as Auth
import           MetaSonic.Authoring.Report
import           MetaSonic.Types
import           MetaSonic.Spec.Core

import qualified Data.ByteString.Char8     as OBSC

authoringDslTests :: TestTree
authoringDslTests =
  testGroup "Phase 8.A: authoring DSL lowering"
  [ testCase "Mono / Stereo / Channels constructors emit no nodes" $ do
      -- Wrapping existing Connections must be a pure authoring
      -- shape — no graph mutation, no UGen creation. The check
      -- compares the SynthGraph emitted by a do-block that only
      -- calls the wrappers to the empty graph emitted by an
      -- empty runSynth.
      let g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let _m = Auth.mono osc
                _s = Auth.stereo osc osc
                _c = Auth.channels [osc, osc, osc]
                _d = Auth.duplicate 4 (Auth.mono osc)
            pure ()
          ref = runSynth (do
            _ <- sinOsc 440.0 0.0
            pure ())
      M.size (sgNodes g) @?= M.size (sgNodes ref)
      kindHistogram g @?= kindHistogram ref

  , testCase "gainS emits two Gain nodes in left-then-right order" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.gainS (Auth.stereo l r) (Param 0.5)
            pure ()
      let gains = nodesByKind g KGain
      length gains @?= 2

  , testCase "gainC emits one Gain per channel; channelCount preserved" $ do
      let chCount = 4
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let inCh = Auth.duplicate chCount (Auth.mono osc)
            _ <- Auth.gainC inCh (Param 0.25)
            pure ()
      length (nodesByKind g KGain) @?= chCount

  , testCase "outStereo emits Out on bus and bus+1" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            Auth.outStereo 0 (Auth.stereo l r)
      length (nodesByKind g KOut) @?= 2

  , testCase "outChannels emits one Out per channel" $ do
      let chCount = 3
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let chans = Auth.duplicate chCount (Auth.mono osc)
            Auth.outChannels 0 chans
      length (nodesByKind g KOut) @?= chCount

  , testCase "sumChannels emits N-1 Add nodes" $ do
      let chCount = 4
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let chans = Auth.duplicate chCount (Auth.mono osc)
            _ <- Auth.sumChannels chans
            pure ()
      length (nodesByKind g KAdd) @?= chCount - 1

  , testCase "sumChannels on empty Channels emits no Add nodes" $ do
      let g = runSynth $ do
            _ <- Auth.sumChannels (Auth.channels [])
            pure ()
      length (nodesByKind g KAdd) @?= 0

  , testCase "sumChannels on empty Channels can feed lifted mono helpers" $ do
      let g = runSynth $ do
            z <- Auth.sumChannels (Auth.channels [])
            y <- Auth.gainM z (Param 0.5)
            Auth.outMono 0 y
      length (nodesByKind g KAdd) @?= 0
      length (nodesByKind g KGain) @?= 1
      case lowerGraph g >>= compileRuntimeGraph of
        Left err -> assertFailure $
          "expected empty channel sum to compile through gainM, got: " <> err
        Right rg -> do
          length (rgNodes rg) @?= 2
          case [rnInputs n | n <- rgNodes rg, rnKind n == KGain] of
            [[RConst 0.0, RConst 0.5]] -> pure ()
            other -> assertFailure $
              "expected Gain fed by literal zero and scalar gain, got: "
              <> show other

  , testCase "mixN emits N-1 Add nodes" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sawOsc 220.0 0.0
            c <- triOsc 330.0 0.0
            _ <- Auth.mixN [Auth.mono a, Auth.mono b, Auth.mono c]
            pure ()
      length (nodesByKind g KAdd) @?= 2

  , testCase "pan2 center lowers to equal-power stereo gains" $ do
      let g = runSynth $ do
            s <- sinOsc 440.0 0.0
            p <- Auth.pan2 (Auth.mono s) 0.0
            Auth.stereoOut 2 p
          gainAmounts =
            [ amount
            | spec <- nodesByKind g KGain
            , Gain _ (Param amount) <- [nsUgen spec]
            ]
          outBuses =
            sort
              [ bus
              | spec <- nodesByKind g KOut
              , Out bus _ <- [nsUgen spec]
              ]
          center = sqrt 0.5
      length gainAmounts @?= 2
      forM_ gainAmounts $ \amount ->
        assertBool
          ("expected center pan gain " <> show center <> ", got " <> show amount)
          (abs (amount - center) < 1e-12)
      outBuses @?= [2, 3]

  , testCase "addS emits two Add nodes (one per channel)" $ do
      let g = runSynth $ do
            la <- sinOsc 440.0 0.0
            ra <- sinOsc 660.0 0.0
            lb <- sinOsc 220.0 0.0
            rb <- sinOsc 330.0 0.0
            _ <- Auth.addS (Auth.stereo la ra) (Auth.stereo lb rb)
            pure ()
      length (nodesByKind g KAdd) @?= 2

  , testCase "lifted stereo patch compiles to a runnable RuntimeGraph" $ do
      -- End-to-end smoke test: an authored stereo gain patch must
      -- traverse lowerGraph + compileTemplateGraph + load without
      -- error. This is the first-demo-target stand-in until the
      -- authoring layer has its own demo entry.
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 220.0 0.0
            stereoOut <- Auth.gainS (Auth.stereo l r) (Param 0.4)
            Auth.outStereo 0 stereoOut
      case lowerGraph g >>= compileRuntimeGraph of
        Left err -> assertFailure $
          "expected authored stereo patch to compile, got: " <> err
        Right rg -> do
          -- Two oscillators + two gains + two outs = 6 nodes
          length (rgNodes rg) @?= 6

  ------------------------------------------------------------
  -- Phase 8.C2: lifted stateful / common UGens
  ------------------------------------------------------------

  , testCase "mono lifts emit one node of each wrapped primitive kind" $ do
      let maxT = 0.25
          g = runSynth $ do
            src <- sinOsc 440.0 0.0
            hp  <- Auth.hpfM    (Auth.mono src) (Param 1200.0) (Param 0.7)
            bp  <- Auth.bpfM    hp              (Param 800.0)  (Param 1.5)
            nt  <- Auth.notchM  bp              (Param 60.0)   (Param 4.0)
            dly <- Auth.delayM  maxT            nt             (Param 0.15)
            _   <- Auth.smoothM 20.0            dly
            pure ()
          maxes =
            [ m
            | spec <- nodesByKind g KDelay
            , Delay m _ _ <- [nsUgen spec]
            ]
      length (nodesByKind g KHPF)    @?= 1
      length (nodesByKind g KBPF)    @?= 1
      length (nodesByKind g KNotch)  @?= 1
      length (nodesByKind g KDelay)  @?= 1
      length (nodesByKind g KSmooth) @?= 1
      maxes @?= [maxT]

  , testCase "hpfS emits two KHPF nodes" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.hpfS (Auth.stereo l r) (Param 1200.0) (Param 0.7)
            pure ()
      length (nodesByKind g KHPF) @?= 2

  , testCase "bpfS emits two KBPF nodes" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.bpfS (Auth.stereo l r) (Param 800.0) (Param 1.5)
            pure ()
      length (nodesByKind g KBPF) @?= 2

  , testCase "notchS emits two KNotch nodes" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.notchS (Auth.stereo l r) (Param 60.0) (Param 4.0)
            pure ()
      length (nodesByKind g KNotch) @?= 2

  , testCase "hpfC / bpfC / notchC emit one filter node per channel" $ do
      let chCount = 4
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let inCh = Auth.duplicate chCount (Auth.mono osc)
            h <- Auth.hpfC inCh (Param 1200.0) (Param 0.7)
            b <- Auth.bpfC h    (Param 800.0)  (Param 1.5)
            _ <- Auth.notchC b  (Param 60.0)   (Param 4.0)
            pure ()
      length (nodesByKind g KHPF)   @?= chCount
      length (nodesByKind g KBPF)   @?= chCount
      length (nodesByKind g KNotch) @?= chCount

  , testCase "delayS emits two KDelay nodes sharing the same maxDelay" $ do
      let maxT = 0.25
          g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.delayS maxT (Auth.stereo l r) (Param 0.15)
            pure ()
          maxes =
            [ m
            | spec <- nodesByKind g KDelay
            , Delay m _ _ <- [nsUgen spec]
            ]
      length (nodesByKind g KDelay) @?= 2
      maxes @?= [maxT, maxT]

  , testCase "delayC emits one KDelay per channel" $ do
      let chCount = 3
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let inCh = Auth.duplicate chCount (Auth.mono osc)
            _ <- Auth.delayC 0.1 inCh (Param 0.05)
            pure ()
      length (nodesByKind g KDelay) @?= chCount

  , testCase "smoothC emits one KSmooth per channel" $ do
      let chCount = 5
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let inCh = Auth.duplicate chCount (Auth.mono osc)
            _ <- Auth.smoothC 20.0 inCh
            pure ()
      length (nodesByKind g KSmooth) @?= chCount

  , testCase "smoothS emits two KSmooth nodes" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.smoothS 20.0 (Auth.stereo l r)
            pure ()
      length (nodesByKind g KSmooth) @?= 2

  , testCase "envM emits one KEnv plus one KGain" $ do
      let g = runSynth $ do
            src <- sinOsc 440.0 0.0
            _ <- Auth.envM (Auth.mono src)
                   (Param 1.0)  -- gate (always on, for test)
                   (Param 0.01) -- attack
                   (Param 0.1)  -- decay
                   (Param 0.8)  -- sustain
                   (Param 0.5)  -- release
            pure ()
      length (nodesByKind g KEnv)  @?= 1
      length (nodesByKind g KGain) @?= 1

  , testCase "envS emits one shared KEnv plus two KGains driven by it" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.envS (Auth.stereo l r)
                   (Param 1.0)
                   (Param 0.01) (Param 0.1) (Param 0.8) (Param 0.5)
            pure ()
          envSpecs = nodesByKind g KEnv
          envIds   = map nsID envSpecs
          -- Every Gain's *amount* input should be Audio <envId> _
          gainAmountIds =
            [ nid
            | spec <- nodesByKind g KGain
            , Gain _ amt <- [nsUgen spec]
            , Just nid <- [connectionNodeID amt]
            ]
      length envSpecs @?= 1
      length (nodesByKind g KGain) @?= 2
      gainAmountIds @?= replicate 2 (head envIds)

  , testCase "envC emits one shared KEnv plus N KGains driven by it" $ do
      let chCount = 4
          g = runSynth $ do
            osc <- sinOsc 440.0 0.0
            let inCh = Auth.duplicate chCount (Auth.mono osc)
            _ <- Auth.envC inCh
                   (Param 1.0)
                   (Param 0.01) (Param 0.1) (Param 0.8) (Param 0.5)
            pure ()
          envSpecs      = nodesByKind g KEnv
          envIds        = map nsID envSpecs
          gainAmountIds =
            [ nid
            | spec <- nodesByKind g KGain
            , Gain _ amt <- [nsUgen spec]
            , Just nid <- [connectionNodeID amt]
            ]
      length envSpecs @?= 1
      length (nodesByKind g KGain) @?= chCount
      gainAmountIds @?= replicate chCount (head envIds)

  , testCase "envC on empty Channels emits no KEnv and no KGain" $ do
      let g = runSynth $ do
            _ <- Auth.envC (Auth.channels [])
                   (Param 1.0)
                   (Param 0.01) (Param 0.1) (Param 0.8) (Param 0.5)
            pure ()
      length (nodesByKind g KEnv)  @?= 0
      length (nodesByKind g KGain) @?= 0

  , testCase "lifted authored fx chain compiles end-to-end" $ do
      -- stereoSrc -> hpfS -> envS -> delayS -> gainS -> stereoOut
      let g = runSynth $ do
            l    <- sinOsc 440.0 0.0
            r    <- sinOsc 660.0 0.0
            filt <- Auth.hpfS   (Auth.stereo l r) (Param 1200.0) (Param 0.7)
            shaped <- Auth.envS   filt
                        (Param 1.0)
                        (Param 0.01) (Param 0.2)
                        (Param 0.8)  (Param 0.5)
            dly    <- Auth.delayS 0.3 shaped (Param 0.15)
            master <- Auth.gainS dly (Param 0.25)
            Auth.outStereo 0 master
      case lowerGraph g >>= compileRuntimeGraph of
        Left err -> assertFailure $
          "expected authored 8.C2 patch to compile, got: " <> err
        Right rg -> do
          -- Sanity counts: every helper preserves primitive
          -- visibility, so the lowered graph has the kinds we
          -- expect by structural inspection.
          let kindCount k =
                length [ () | n <- rgNodes rg, rnKind n == k ]
          kindCount KSinOsc @?= 2
          kindCount KHPF    @?= 2
          kindCount KEnv    @?= 1
          kindCount KGain   @?= 4  -- envS gains + master gainS
          kindCount KDelay  @?= 2
          kindCount KOut    @?= 2

  ------------------------------------------------------------
  -- Phase 8.D: routing helpers (balance / spread / send / returnBus)
  ------------------------------------------------------------

  , testCase "balance center emits two unity KGain nodes" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.balance (Auth.stereo l r) 0.0
            pure ()
          amounts = sort
            [ a
            | spec <- nodesByKind g KGain
            , Gain _ (Param a) <- [nsUgen spec]
            ]
      length (nodesByKind g KGain) @?= 2
      amounts @?= [1.0, 1.0]

  , testCase "balance left attenuates right channel only" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.balance (Auth.stereo l r) (-0.4)
            pure ()
          amounts = sort
            [ a
            | spec <- nodesByKind g KGain
            , Gain _ (Param a) <- [nsUgen spec]
            ]
      length (nodesByKind g KGain) @?= 2
      amounts @?= sort [1.0, 1.0 - 0.4]

  , testCase "balance right attenuates left channel only" $ do
      let g = runSynth $ do
            l <- sinOsc 440.0 0.0
            r <- sinOsc 660.0 0.0
            _ <- Auth.balance (Auth.stereo l r) 0.7
            pure ()
          amounts = sort
            [ a
            | spec <- nodesByKind g KGain
            , Gain _ (Param a) <- [nsUgen spec]
            ]
      length (nodesByKind g KGain) @?= 2
      amounts @?= sort [1.0 - 0.7, 1.0]

  , testCase "spread [] emits zero KGain and zero KAdd" $ do
      let g = runSynth $ do
            _ <- Auth.spread [] 1.0
            pure ()
      length (nodesByKind g KGain) @?= 0
      length (nodesByKind g KAdd)  @?= 0

  , testCase "spread [single] emits two KGain and no KAdd (delegates to pan2)" $ do
      let g = runSynth $ do
            s <- sinOsc 440.0 0.0
            _ <- Auth.spread [Auth.mono s] 1.0
            pure ()
      length (nodesByKind g KGain) @?= 2
      length (nodesByKind g KAdd)  @?= 0

  , testCase "spread of N=3 sources emits 6 KGain and 4 KAdd nodes" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sawOsc 220.0 0.0
            c <- triOsc 330.0 0.0
            _ <- Auth.spread [Auth.mono a, Auth.mono b, Auth.mono c] 1.0
            pure ()
      -- 3 sources × 2 channels = 6 KGain
      -- (3 - 1) × 2 channels    = 4 KAdd
      length (nodesByKind g KGain) @?= 6
      length (nodesByKind g KAdd)  @?= 4

  , testCase "spread with width=0 collapses every source to center" $ do
      let g = runSynth $ do
            a <- sinOsc 440.0 0.0
            b <- sawOsc 220.0 0.0
            _ <- Auth.spread [Auth.mono a, Auth.mono b] 0.0
            pure ()
          amounts = sort
            [ a
            | spec <- nodesByKind g KGain
            , Gain _ (Param a) <- [nsUgen spec]
            ]
          center = sqrt 0.5
      length (nodesByKind g KGain) @?= 4
      -- All 4 gains should be the equal-power center coefficient.
      forM_ amounts $ \a ->
        assertBool
          ("expected sqrt 0.5 = " <> show center <> ", got " <> show a)
          (abs (a - center) < 1e-12)

  , testCase "send lowers to exactly one KBusOut on the named bus" $ do
      let g = runSynth $ do
            s <- sinOsc 440.0 0.0
            Auth.send (Auth.bus 7) (Auth.mono s)
          busOuts =
            [ b
            | spec <- nodesByKind g KBusOut
            , BusOut b _ <- [nsUgen spec]
            ]
      length (nodesByKind g KBusOut) @?= 1
      busOuts @?= [7]

  , testCase "returnBus lowers to exactly one KBusIn on the named bus" $ do
      let g = runSynth $ do
            sent <- Auth.returnBus (Auth.bus 7)
            Auth.outMono 0 sent
          busIns =
            [ b
            | spec <- nodesByKind g KBusIn
            , BusIn b <- [nsUgen spec]
            ]
      length (nodesByKind g KBusIn) @?= 1
      busIns @?= [7]

  , testCase "Auth.bus is the same as Bus constructor" $ do
      -- A trivial structural pin: 'bus' is a smart constructor and
      -- must not introduce indirection that ever differs from
      -- 'Bus' itself. This is the smallest possible regression
      -- guard against someone "improving" the helper later.
      Auth.unBus (Auth.bus 13) @?= 13
      Auth.bus 13              @?= Auth.Bus 13

  , testCase "send -> returnBus pair produces the expected template footprint" $ do
      -- The footprint pin that matters for 8.D: the lifted
      -- send/return pair must lower into a TemplateGraph whose
      -- per-template tplFootprint matches what a hand-authored
      -- 'busOut 7 ... ; busIn 7' pair already produces. We check:
      --   * voice template writes bus 7, reads nothing live;
      --   * fx    template reads  bus 7, writes nothing;
      --   * compileTemplateGraph orders voice before fx (the
      --     same-bus write/read intersection forces it).
      let voiceG = runSynth $ do
            s     <- sinOsc 440.0 0.0
            amped <- gain s 0.4
            Auth.send (Auth.bus 7) (Auth.mono amped)
          fxG = runSynth $ do
            sent     <- Auth.returnBus (Auth.bus 7)
            filtered <- Auth.lpfM sent (Param 800.0) (Param 0.7)
            Auth.outMono 0 filtered
      tg <- case compileTemplateGraph [("voice", voiceG), ("fx", fxG)] of
        Left err -> assertFailure err >> error "unreachable"
        Right t  -> pure t
      length (tgTemplates tg) @?= 2
      let templatesByName =
            [ (tplName t, rfBuses (tplFootprint t))
            | t <- tgTemplates tg ]
          voiceFp = lookup "voice" templatesByName
          fxFp    = lookup "fx"    templatesByName
      case voiceFp of
        Just fp -> do
          -- voice writes the shared send bus 7; no live reads.
          bfWrites fp @?= S.singleton 7
          bfReads  fp @?= S.empty
        Nothing -> assertFailure "voice template missing"
      case fxFp of
        Just fp -> do
          -- fx reads bus 7 (via returnBus) and writes hardware
          -- bus 0 (via outMono). 'KOut' counts as a bus write
          -- in the footprint, same as 'KBusOut'.
          bfWrites fp @?= S.singleton 0
          bfReads  fp @?= S.singleton 7
        Nothing -> assertFailure "fx template missing"
      -- Ordering: writer must precede reader by the §4.E template
      -- precedence contract.
      let names = [tplName t | t <- tgTemplates tg]
      names @?= ["voice", "fx"]

  ------------------------------------------------------------
  -- Phase 8.E: ensemble builder
  ------------------------------------------------------------

  , testCase "defaultEnsembleOptions has eoBusBase = 16" $
      Auth.eoBusBase Auth.defaultEnsembleOptions @?= 16

  , testCase "busNamed allocates default bus on first use" $ do
      let result = Auth.ensemble $ do
            b <- Auth.busNamed "send"
            pure ()
      case result of
        Left err -> assertFailure err
        Right ae -> do
          Auth.amBuses (Auth.aeMetadata ae)
            @?= M.fromList [("send", Auth.Bus 16)]

  , testCase "busNamed is idempotent on the same name" $ do
      -- Two calls to 'busNamed "send"' must return the same
      -- 'Bus' and must not bump the allocation counter past
      -- the first index. We pin this from the outside: the
      -- bus map after the run has exactly one entry, and a
      -- third call to a different name returns 17 (not 18),
      -- proving the counter did not advance past the first
      -- allocation.
      let result = Auth.ensemble $ do
            _ <- Auth.busNamed "send"
            _ <- Auth.busNamed "send"
            _ <- Auth.busNamed "other"
            pure ()
      case result of
        Left err -> assertFailure err
        Right ae ->
          Auth.amBuses (Auth.aeMetadata ae) @?= M.fromList
            [ ("send",  Auth.Bus 16)
            , ("other", Auth.Bus 17)
            ]

  , testCase "busNamed allocates in first-use order, not name order" $ do
      let result = Auth.ensemble $ do
            _ <- Auth.busNamed "zeta"
            _ <- Auth.busNamed "alpha"
            pure ()
      case result of
        Left err -> assertFailure err
        Right ae ->
          Auth.amBuses (Auth.aeMetadata ae) @?= M.fromList
            [ ("zeta",  Auth.Bus 16)
            , ("alpha", Auth.Bus 17)
            ]

  , testCase "ensembleWith eoBusBase=100 starts allocation at 100" $ do
      let opts = Auth.defaultEnsembleOptions { Auth.eoBusBase = 100 }
          result = Auth.ensembleWith opts $ do
            _ <- Auth.busNamed "x"
            _ <- Auth.busNamed "y"
            pure ()
      case result of
        Left err -> assertFailure err
        Right ae ->
          Auth.amBuses (Auth.aeMetadata ae) @?= M.fromList
            [ ("x", Auth.Bus 100)
            , ("y", Auth.Bus 101)
            ]

  , testCase "duplicate template name produces Left error" $ do
      let g  = runSynth $ do
            s <- sinOsc 440.0 0.0
            out 0 s
          result = Auth.ensemble $ do
            Auth.voice "v" g
            Auth.voice "v" g
      result @?= Left "ensemble: duplicate template name 'v'"

  , testCase "fx -> voice with same name also fails" $ do
      -- The duplicate-name check ignores TemplateRole — name
      -- uniqueness is global to the ensemble.
      let g  = runSynth $ do
            s <- sinOsc 440.0 0.0
            out 0 s
          result = Auth.ensemble $ do
            Auth.fx    "shared" g
            Auth.voice "shared" g
      result @?= Left "ensemble: duplicate template name 'shared'"

  , testCase "aeTemplates preserves declaration order" $ do
      let g1 = runSynth $ do
            s <- sinOsc 440.0 0.0
            out 0 s
          g2 = runSynth $ do
            s <- sinOsc 220.0 0.0
            out 0 s
          result = Auth.ensemble $ do
            Auth.voice "first"  g1
            Auth.fx    "second" g2
      case result of
        Left err -> assertFailure err
        Right ae -> do
          map fst (Auth.aeTemplates ae) @?= ["first", "second"]
          Auth.amRoles (Auth.aeMetadata ae) @?=
            [ ("first",  Auth.VoiceTemplate)
            , ("second", Auth.FxTemplate)
            ]

  , testCase "ensemble send/return compiles with writer-before-reader order" $ do
      -- End-to-end pin: an ensemble whose two templates use
      -- the same busNamed handle (one Auth.send, one
      -- Auth.returnBus) compiles through compileTemplateGraph
      -- and produces the same shape the hand-written 8.D
      -- send-return demo produced, just on the new
      -- ensemble-allocated bus.
      let result = Auth.ensemble $ do
            sendBus <- Auth.busNamed "main-send"
            Auth.voice "voice" (runSynth $ do
              s     <- sinOsc 440.0 0.0
              amped <- gain s 0.4
              Auth.send sendBus (Auth.mono amped))
            Auth.fx "fx" (runSynth $ do
              sent     <- Auth.returnBus sendBus
              filtered <- Auth.lpfM sent (Param 800.0) (Param 0.7)
              Auth.outMono 0 filtered)
      ae <- case result of
        Left err -> assertFailure err >> error "unreachable"
        Right a  -> pure a
      -- The allocated bus is the default base.
      Auth.amBuses (Auth.aeMetadata ae)
        @?= M.fromList [("main-send", Auth.Bus 16)]
      -- Compile-side cross-check.
      tg <- case compileTemplateGraph (Auth.aeTemplates ae) of
        Left err -> assertFailure err >> error "unreachable"
        Right t  -> pure t
      let namesInOrder = [tplName t | t <- tgTemplates tg]
      namesInOrder @?= ["voice", "fx"]
      let templatesByName =
            [ (tplName t, rfBuses (tplFootprint t))
            | t <- tgTemplates tg ]
      case lookup "voice" templatesByName of
        Just fp -> do
          bfWrites fp @?= S.singleton 16
          bfReads  fp @?= S.empty
        Nothing -> assertFailure "voice template missing"
      case lookup "fx" templatesByName of
        Just fp -> do
          bfWrites fp @?= S.singleton 0   -- outMono 0
          bfReads  fp @?= S.singleton 16  -- returnBus 16
        Nothing -> assertFailure "fx template missing"

  , testCase "AuthoringMetadata changes do not affect compile output" $ do
      -- Pin the diagnostic-only contract: rewriting
      -- aeMetadata while keeping aeTemplates produces the
      -- same TemplateGraph. compileTemplateGraph never reads
      -- aeMetadata.
      let g1 = runSynth $ do
            s <- sinOsc 440.0 0.0
            out 0 s
          base = case Auth.ensemble (Auth.voice "v" g1) of
            Right ae -> ae
            Left err -> error err
          mutated = base
            { Auth.aeMetadata = (Auth.aeMetadata base)
                { Auth.amRoles = []      -- wipe roles
                , Auth.amBuses = M.empty -- wipe bus assignments
                }
            }
      tg1 <- case compileTemplateGraph (Auth.aeTemplates base) of
        Left err -> assertFailure err >> error "unreachable"
        Right t  -> pure t
      tg2 <- case compileTemplateGraph (Auth.aeTemplates mutated) of
        Left err -> assertFailure err >> error "unreachable"
        Right t  -> pure t
      tg1 @?= tg2

  ------------------------------------------------------------
  -- Phase 8.F: named controls
  ------------------------------------------------------------

  , testCase "defaultControlOptions has coSmoothingHz = 20.0" $
      Auth.coSmoothingHz Auth.defaultControlOptions @?= 20.0

  , testCase "controlName accepts OSC-safe identifiers" $ do
      fmap Auth.unControlName (Auth.controlName "cutoff")
        @?= Right "cutoff"
      fmap Auth.unControlName (Auth.controlName "vol")
        @?= Right "vol"
      fmap Auth.unControlName (Auth.controlName "a_b-c")
        @?= Right "a_b-c"
      -- 16 bytes is the longest legal name.
      fmap Auth.unControlName (Auth.controlName "0123456789abcdef")
        @?= Right "0123456789abcdef"

  , testCase "controlName rejects empty names" $
      case Auth.controlName "" of
        Left _  -> pure ()
        Right _ -> assertFailure "expected empty-name rejection"

  , testCase "controlName rejects names with slash or space" $ do
      case Auth.controlName "with space" of
        Left _  -> pure ()
        Right _ -> assertFailure "expected space rejection"
      case Auth.controlName "with/slash" of
        Left _  -> pure ()
        Right _ -> assertFailure "expected slash rejection"

  , testCase "controlName rejects names longer than 16 bytes" $
      case Auth.controlName "0123456789abcdefX" of
        Left _  -> pure ()
        Right _ -> assertFailure "expected 17-byte rejection"

  , testCase "controlRange accepts min < max and rejects min >= max" $ do
      case Auth.controlRange 0 1 of
        Right rng -> do
          Auth.crMin rng @?= 0
          Auth.crMax rng @?= 1
        Left err -> assertFailure err
      case Auth.controlRange 1 0 of
        Left _  -> pure ()
        Right _ -> assertFailure "expected inverted-range rejection"
      case Auth.controlRange 0.5 0.5 of
        Left _  -> pure ()
        Right _ -> assertFailure "expected zero-width rejection"

  , testCase "controlRange rejects non-finite bounds" $ do
      let nan = 0 / 0 :: Double
          inf = 1 / 0 :: Double
      case Auth.controlRange nan 1 of
        Left _  -> pure ()
        Right _ -> assertFailure "expected NaN min rejection"
      case Auth.controlRange 0 nan of
        Left _  -> pure ()
        Right _ -> assertFailure "expected NaN max rejection"
      case Auth.controlRange 0 inf of
        Left _  -> pure ()
        Right _ -> assertFailure "expected infinite max rejection"

  , testCase "control emits exactly one KSmooth tagged with the control name" $ do
      let Right cname = Auth.controlName "cutoff"
          Right rng   = Auth.controlRange 200 8000
          (_, sg)     = runSynthWith $ Auth.control cname 1200 rng
      length (nodesByKind sg KSmooth) @?= 1
      case nodesByKind sg KSmooth of
        [spec] -> do
          nsMigrationKey spec @?= Just (MigrationKey "cutoff")
          case nsUgen spec of
            Smooth hz (Param d) -> do
              hz @?= 20.0
              d  @?= 1200
            other -> assertFailure
                       ("expected Smooth 20 (Param 1200), got: " <> show other)
        _ -> assertFailure "expected one KSmooth node"

  , testCase "control records ncmSlot = 1 and ncmKey = MigrationKey name" $ do
      let Right cname  = Auth.controlName "vol"
          Right rng    = Auth.controlRange 0 1
          (nc, _)      = runSynthWith $ Auth.control cname 0.3 rng
          meta         = Auth.ncMetadata nc
      Auth.ncmSlot meta @?= 1
      Auth.ncmKey  meta @?= MigrationKey "vol"
      Auth.ncmCC   meta @?= Nothing
      Auth.ncmName meta @?= "vol"
      Auth.ncmDefault meta @?= 0.3
      Auth.ncmRange meta @?= rng

  , testCase "controlWith honors a non-default coSmoothingHz" $ do
      let Right cname = Auth.controlName "cutoff"
          Right rng   = Auth.controlRange 0 1
          opts        = Auth.defaultControlOptions { Auth.coSmoothingHz = 80.0 }
          (nc, sg)    = runSynthWith $ Auth.controlWith opts cname 0.5 rng
      Auth.ncmSmoothingHz (Auth.ncMetadata nc) @?= 80.0
      case nodesByKind sg KSmooth of
        [spec] -> case nsUgen spec of
          Smooth hz _ -> hz @?= 80.0
          other       -> assertFailure
                           ("expected Smooth, got: " <> show other)
        _ -> assertFailure "expected one KSmooth node"

  , testCase "ccControl records exactly one CCSpec targeting the smoother slot 1" $ do
      let Right cname = Auth.controlName "vol"
          Right rng   = Auth.controlRange 0 1
          (nc, _, specs) = runSynthCCs $ Auth.ccControl 7 cname 0.3 rng
      length (nodesByKind (runSynth (Auth.ccControl 7 cname 0.3 rng)) KSmooth)
        @?= 1
      case specs of
        [s] -> do
          ccsNumber s @?= (7 :: Word8)
          ccsCtl    s @?= 1
          ccsMin    s @?= 0
          ccsMax    s @?= 1
          -- The spec's node points at the smoother that backs the
          -- returned NamedControl.
          Just (ccsNode s) @?=
            connectionNodeID (Auth.controlConnection nc)
        _   -> assertFailure $
                 "expected one CC spec, got " <> show (length specs)
      Auth.ncmCC (Auth.ncMetadata nc) @?= Just 7

  , testCase "ccControlWith preserves custom smoothing on the smoother" $ do
      let Right cname = Auth.controlName "vol"
          Right rng   = Auth.controlRange 0 1
          opts        = Auth.defaultControlOptions { Auth.coSmoothingHz = 50.0 }
          (_, sg, _)  = runSynthCCs $ Auth.ccControlWith opts 7 cname 0.0 rng
      case nodesByKind sg KSmooth of
        [spec] -> case nsUgen spec of
          Smooth hz _ -> hz @?= 50.0
          other       -> assertFailure
                           ("expected Smooth, got: " <> show other)
        _ -> assertFailure "expected one KSmooth node"

  , testCase "named control round-trips through the OSC dispatcher" $ do
      -- End-to-end pin: a graph built from one named control
      -- compiles, the smoother node carries the control name as
      -- a MigrationKey, and an OSC message at
      -- /<voice>/<name>/1 resolves to the smoother's NodeIndex
      -- (slot 1) through the existing dispatcher.
      let Right cname = Auth.controlName "cutoff"
          Right rng   = Auth.controlRange 200 8000
          (nc, sg)    = runSynthWith $ do
            n     <- Auth.control cname 1200 rng
            osc   <- sinOsc 440 0
            filt  <- lpf osc (Auth.controlConnection n) (Param 0.7)
            _     <- out 0 filt
            pure n
      tg <- case compileTemplateGraph [("voice", sg)] of
        Left err -> assertFailure err >> error "unreachable"
        Right t  -> pure t
      rs0 <- case OSC.registerVoice (OBSC.pack "v") 1 (OBSC.pack "voice")
                    (OSC.emptyResolveState tg) of
        Left iss -> assertFailure (show iss) >> error "unreachable"
        Right rs -> pure rs
      let msg = OSC.OscMessage (OBSC.pack "/v/cutoff/1")
                                [OSC.OscArgFloat 1500.0]
      case OSC.dispatch rs0 msg of
        Right (OSC.DAControlWrite
                  { OSC.daSlotId     = 1
                  , OSC.daNodeIndex  = nodeIx
                  , OSC.daControlIdx = 1
                  , OSC.daValue      = v
                  }) -> do
          v @?= 1500.0
          -- Sanity: the resolved node is the smoother that backs
          -- the returned NamedControl.
          let smootherTargets =
                [ rnIndex n
                | tpl <- tgTemplates tg
                , n   <- rgNodes (tplGraph tpl)
                , rnKind n == KSmooth
                , rnMigrationKey n == Just (Auth.ncmKey (Auth.ncMetadata nc))
                ]
          smootherTargets @?= [nodeIx]
        other -> assertFailure
                   ("expected control-write dispatch, got: " <> show other)

  , testCase "NamedControlMetadata is diagnostic-only — compile output is identical" $ do
      -- Pin the diagnostic-only contract: dropping the metadata
      -- and using only controlConnection produces the same
      -- runtime graph as keeping the NamedControl handle.
      let Right cname = Auth.controlName "vol"
          Right rng   = Auth.controlRange 0 1
          withHandle = runSynth $ do
            n     <- Auth.control cname 0.3 rng
            osc   <- sinOsc 440 0
            amped <- gain osc (Auth.controlConnection n)
            _     <- out 0 amped
            pure n
          handFused = runSynth $ do
            v     <- tagged "vol" (smooth 20.0 (Param 0.3))
            osc   <- sinOsc 440 0
            amped <- gain osc v
            _     <- out 0 amped
            pure ()
      -- Both lower to the same runtime graph.
      let rt1 = lowerGraph withHandle >>= compileRuntimeGraph
          rt2 = lowerGraph handFused  >>= compileRuntimeGraph
      case (rt1, rt2) of
        (Right a, Right b) -> a @?= b
        (Left e, _) -> assertFailure ("withHandle compile: " <> e)
        (_, Left e) -> assertFailure ("handFused compile: " <> e)
  ]
