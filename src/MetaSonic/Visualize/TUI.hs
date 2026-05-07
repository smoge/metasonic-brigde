{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- |
-- Module      : MetaSonic.Visualize.TUI
-- Description : Terminal UI for inspecting compilation
--
-- Launch with 'inspectGraph' (input: 'SynthGraph') or
-- 'launchInspector' (input: a pre-computed 'CompileTrace').
--
-- This module is intentionally read-only re: compilation.
-- It renders a pure 'CompileTrace' snapshot and doesn't run compiler
-- passes.

module MetaSonic.Visualize.TUI
  ( inspectGraph
  , launchInspector
  ) where

import           Brick
import           Brick.Widgets.Border
import           Brick.Widgets.Border.Style
import           Brick.Widgets.Center       (hCenter)
import           Control.Monad              (void)
import           Control.Monad.State.Strict (modify)
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import qualified Graphics.Vty               as V
import qualified Graphics.Vty.CrossPlatform as VCP
import           Lens.Micro
import           Lens.Micro.Mtl
import           Lens.Micro.TH

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Types
import           MetaSonic.Visualize.Trace

data Name
  = NodePanel
  | DetailPanel
  deriving (Eq, Ord, Show)

data AppState = AppState
  { _asStage    :: TraceStage
  , _asSelected :: Int
  , _asTrace    :: CompileTrace
  }

makeLenses ''AppState

allStages :: [TraceStage]
allStages = [minBound .. maxBound]

stageLabel :: TraceStage -> String
stageLabel = \case
  TraceSource  -> "Source"
  TraceOrder   -> "Toposort"
  TraceIR      -> "IR"
  TraceRegions -> "Regions"
  TraceRuntime -> "Dense"

stageDesc :: TraceStage -> String
stageDesc = \case
  TraceSource  -> "Source graph nodes, shown in execution order when available"
  TraceOrder   -> "validateAndSort: referential integrity + topological order"
  TraceIR      -> "lowerGraph: semantic IR (kind, rate, effects, inputs, controls)"
  TraceRegions -> "formRegions: greedy rate-compatible execution groups"
  TraceRuntime -> "compileRuntimeGraph: dense NodeIndex form (sent by FFI)"

nodeCount :: CompileTrace -> TraceStage -> Int
nodeCount ct = \case
  TraceSource  -> length (traceSourceNodes ct)
  TraceOrder   -> maybe 0 length (ctExecOrder ct)
  TraceIR      -> maybe 0 (length . giNodes) (ctIR ct)
  TraceRegions -> maybe 0 (sum . map (length . regNodes) . rgRegions) (ctRegions ct)
  TraceRuntime -> maybe 0 (length . rgNodes) (ctRuntime ct)

clampIndex :: Int -> Int -> Int
clampIndex n i
  | n <= 0    = 0
  | otherwise = max 0 (min (n - 1) i)

clampSelection :: AppState -> AppState
clampSelection st =
  let n = nodeCount (st ^. asTrace) (st ^. asStage)
  in  st & asSelected %~ clampIndex n

safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
  | i < 0     = Nothing
  | otherwise = case drop i xs of
      y : _ -> Just y
      []    -> Nothing

showNodeID :: NodeID -> String
showNodeID (NodeID x) = "NodeID " <> show x

showNodeIndex :: NodeIndex -> String
showNodeIndex (NodeIndex x) = show x

showRegionID :: RegionID -> String
showRegionID (RegionID x) = "R" <> show x

inspectGraph :: SynthGraph -> IO ()
inspectGraph = launchInspector . traceCompile

launchInspector :: CompileTrace -> IO ()
launchInspector ct = do
  let buildVty = VCP.mkVty V.defaultConfig
  vty <- buildVty
  void $ customMain vty buildVty Nothing app (AppState TraceSource 0 ct)

drawUI :: AppState -> [Widget Name]
drawUI st =
  [ vBox
      [ drawHeader
      , drawTabs st
      , drawDesc st
      , hBox
          [ hLimitPercent 45 (drawNodePanel st)
          , vBorder
          , drawDetailPanel st
          ]
      , drawStatusBar st
      ]
  ]

drawHeader :: Widget Name
drawHeader =
  withAttr headerAttr $
    hCenter $
      str "MetaSonic Pipeline Inspector"

drawTabs :: AppState -> Widget Name
drawTabs st =
  padLeftRight 1 $
    hBox (map drawTab allStages)
  where
    ct = st ^. asTrace

    drawTab :: TraceStage -> Widget Name
    drawTab s =
      let current = s == st ^. asStage
          failed  = ctFailedAt ct == Just s
          reached = traceReached ct s

          attr'
            | current   = tabSelAttr
            | failed    = tabFailAttr
            | reached   = tabAttr
            | otherwise = tabDimAttr

          marker
            | current   = "▸"
            | failed    = "✗"
            | reached   = " "
            | otherwise = "·"
      in
        withAttr attr' $
          padLeftRight 1 $
            str (marker <> " " <> stageLabel s <> " ")

drawDesc :: AppState -> Widget Name
drawDesc st =
  let stage = st ^. asStage
      ct    = st ^. asTrace
      extra = case traceStageError ct stage of
        Just e  -> "  ✗ " <> e
        Nothing ->
          case ctFailedAt ct of
            Just failed
              | failed /= stage && not (traceReached ct stage) ->
                  "  (blocked by failure at " <> stageLabel failed <> ")"
            _ ->
              ""
  in
    padLeftRight 2 $
      withAttr helpAttr (str (stageDesc stage))
      <+> withAttr errAttr (str extra)

drawNodePanel :: AppState -> Widget Name
drawNodePanel st =
  withBorderStyle unicode $
    borderWithLabel (withAttr titleAttr $ str title') $
      viewport NodePanel Vertical $
        padRight Max $
          vBox rows
  where
    stage  = st ^. asStage
    ct     = st ^. asTrace
    sel    = st ^. asSelected
    title' = " " <> stageLabel stage <> " "

    rows = case stage of
      TraceSource  ->
        zipWith (nodeRow sel) [0 ..] (map fmtSource (traceSourceNodes ct))

      TraceOrder   ->
        maybe [notReached]
              (zipWith (nodeRow sel) [0 ..] . fmtOrderRows)
              (ctExecOrder ct)

      TraceIR      ->
        maybe [notReached]
              (zipWith (nodeRow sel) [0 ..] . map fmtIR . giNodes)
              (ctIR ct)

      TraceRegions ->
        maybe [notReached] (fmtRegionRows sel) (ctRegions ct)

      TraceRuntime ->
        maybe [notReached]
              (zipWith (nodeRow sel) [0 ..] . map fmtDense . rgNodes)
              (ctRuntime ct)

fmtOrderRows :: [NodeID] -> [String]
fmtOrderRows order =
  [ show i <> ". " <> showNodeID nid
  | (i, nid) <- zip [0 :: Int ..] order
  ]

nodeRow :: Int -> Int -> String -> Widget Name
nodeRow sel i txt =
  let attr' = if i == sel then nodeSelAttr else nodeAttr
      mark  = if i == sel then "▶ " else "  "
      base  = withAttr attr' $ padRight Max $ str (mark <> txt)
  in
    if i == sel then visible base else base

notReached :: Widget Name
notReached =
  withAttr errAttr $
    str "  (stage not reached)"

fmtSource :: NodeSpec -> String
fmtSource spec =
  showNodeID (nsID spec)
    <> "  [" <> nsName spec <> "]  "
    <> show (nsUgen spec)

fmtIR :: NodeIR -> String
fmtIR n =
  showNodeID (irNodeID n)
    <> " : " <> show (irKind n)
    <> " @ " <> show (irRate n)
    <> "  eff=" <> fmtEffs (irEffects n)

fmtEffs :: [Eff] -> String
fmtEffs [Pure] = "Pure"
fmtEffs effs   = show effs

fmtInputConn :: InputConn -> String
fmtInputConn (FromNode nid (PortIndex p)) = showNodeID nid <> ":" <> show p
fmtInputConn (Literal x)                  = show x

fmtRegionRows :: Int -> RegionGraph -> [Widget Name]
fmtRegionRows sel rg = go 0 (rgRegions rg)
  where
    go _ [] = []
    go idx (r : rest) =
      let hdr =
            withAttr regionHdrAttr $
              str
                ( "── " <> showRegionID (regID r)
               <> " [" <> show (regRate r) <> "]"
               <> " deps=" <> fmtRegionDeps (regDeps r)
                )

          nodeRows =
            [ nodeRow sel (idx + i) ("  " <> showNodeID nid)
            | (i, nid) <- zip [0 :: Int ..] (regNodes r)
            ]
      in
        hdr : nodeRows <> go (idx + length (regNodes r)) rest

fmtRegionDeps :: S.Set RegionID -> String
fmtRegionDeps deps
  | S.null deps = "{}"
  | otherwise   = "{" <> unwords (map showRegionID (S.toList deps)) <> "}"

fmtDense :: RuntimeNode -> String
fmtDense n =
  "[" <> showNodeIndex (rnIndex n) <> "] "
    <> show (rnKind n)
    <> "  ← "
    <> unwords (map fmtRtInput (rnInputs n))

fmtRtInput :: RuntimeInput -> String
fmtRtInput (RFrom ix (PortIndex p)) = "[" <> showNodeIndex ix <> "]:" <> show p
fmtRtInput (RConst x)               = show x

drawDetailPanel :: AppState -> Widget Name
drawDetailPanel st =
  withBorderStyle unicode $
    borderWithLabel (withAttr titleAttr $ str " detail ") $
      viewport DetailPanel Vertical $
        padAll 1 $
          drawDetail (st ^. asTrace) (st ^. asStage) (st ^. asSelected)

drawDetail :: CompileTrace -> TraceStage -> Int -> Widget Name
drawDetail ct stage sel =
  case stage of
    TraceSource ->
      maybe (str "(no selection)")
            detailSource
            (safeIndex (traceSourceNodes ct) sel)

    TraceOrder ->
      case ctExecOrder ct >>= (`safeIndex` sel) of
        Nothing  -> notReached
        Just nid -> detailOrder ct sel nid

    TraceIR ->
      case ctIR ct of
        Nothing -> notReached
        Just ir ->
          maybe (str "(no selection)")
                (detailIR ir)
                (safeIndex (giNodes ir) sel)

    TraceRegions ->
      maybe notReached (`detailRegion` sel) (ctRegions ct)

    TraceRuntime ->
      case ctRuntime ct of
        Nothing -> notReached
        Just rt ->
          maybe (str "(no selection)")
                (detailDense ct rt)
                (safeIndex (rgNodes rt) sel)

detailOrder :: CompileTrace -> Int -> NodeID -> Widget Name
detailOrder ct sel nid =
  let sourceInfo =
        case safeIndex (traceSourceNodes ct) sel of
          Nothing   -> []
          Just spec ->
            [ section "Name" (nsName spec)
            , section "UGen" (show (nsUgen spec))
            ]
  in
    vBox $
      [ section "Execution position" (show sel)
      , section "NodeID" (showNodeID nid)
      ]
      <> sourceInfo
      <> [ str ""
         , withAttr helpAttr $ str "This list order = validated topological order."
         , withAttr helpAttr $ str "Its zero-based position becomes dense NodeIndex later."
         ]

detailSource :: NodeSpec -> Widget Name
detailSource spec =
  vBox
    [ section "NodeID" (showNodeID (nsID spec))
    , section "Name" (nsName spec)
    , str ""
    , withAttr titleAttr $ str "UGen"
    , str ("  " <> show (nsUgen spec))
    , str ""
    , withAttr titleAttr $ str "Structural dependencies"
    , vBox $
        case dependencies (nsUgen spec) of
          [] -> [str "  (none)"]
          ds -> [str ("  → " <> showNodeID d) | d <- ds]
    ]

detailIR :: GraphIR -> NodeIR -> Widget Name
detailIR ir n =
  let consumers = irConsumers (giNodes ir) (irNodeID n)
  in
    vBox
      [ section "NodeID" (showNodeID (irNodeID n))
      , section "Kind" (show (irKind n))
      , section "Rate" (show (irRate n))
      , section "Effects" (fmtEffs (irEffects n))
      , str ""
      , withAttr titleAttr $ str "Inputs"
      , vBox $
          case irInputs n of
            []   -> [str "  (none)"]
            inps ->
              [ str ("  :" <> show i <> " ← " <> fmtInputConn inp)
              | (i, inp) <- zip [0 :: Int ..] inps
              ]
      , str ""
      , withAttr titleAttr $ str "Controls"
      , str ("  " <> show (irControls n))
      , str ""
      , withAttr titleAttr $ str "Feeds into"
      , vBox $
          case consumers of
            [] -> [str "  (terminal node)"]
            cs ->
              [ str ("  → " <> showNodeID cid <> " :" <> show port)
              | (cid, port) <- cs
              ]
      ]

irConsumers :: [NodeIR] -> NodeID -> [(NodeID, Int)]
irConsumers nodes nid =
  [ (irNodeID n, i)
  | n <- nodes
  , (i, FromNode src _) <- zip [0 :: Int ..] (irInputs n)
  , src == nid
  ]

detailRegion :: RegionGraph -> Int -> Widget Name
detailRegion rg sel =
  case lookupRegionNode rg sel of
    Nothing ->
      str "(no selection)"

    Just (region, nid, posInRegion) ->
      let members = regNodes region
          marker i = if i == posInRegion then "▶ " else "  "
      in
        vBox
          [ section "NodeID" (showNodeID nid)
          , str ""
          , withAttr titleAttr $ str "Region"
          , section "  ID" (showRegionID (regID region))
          , section "  Rate" (show (regRate region))
          , section "  Deps" (fmtRegionDeps (regDeps region))
          , section "  Size" (show (length members) <> " nodes")
          , section "  Position" (show (posInRegion + 1) <> " of " <> show (length members))
          , str ""
          , withAttr titleAttr $ str "Region members"
          , vBox
              [ str ("  " <> marker i <> showNodeID m)
              | (i, m) <- zip [0 :: Int ..] members
              ]
          , str ""
          , withAttr titleAttr $ str "Effects (union)"
          , str ("  " <> fmtEffs (regEffects region))
          ]

lookupRegionNode :: RegionGraph -> Int -> Maybe (Region, NodeID, Int)
lookupRegionNode rg sel = go 0 (rgRegions rg)
  where
    go _ [] = Nothing
    go offset (r : rest)
      | sel < offset + length (regNodes r) =
          let posInRegion = sel - offset
          in case safeIndex (regNodes r) posInRegion of
               Nothing  -> Nothing
               Just nid -> Just (r, nid, posInRegion)
      | otherwise =
          go (offset + length (regNodes r)) rest

detailDense :: CompileTrace -> RuntimeGraph -> RuntimeNode -> Widget Name
detailDense ct rt n =
  let consumers = rtConsumers (rgNodes rt) (rnIndex n)
  in
    vBox
      [ section "NodeIndex" (showNodeIndex (rnIndex n))
      , section "Kind" (show (rnKind n))
      , section "Original NodeID" (showNodeID (rnOriginalID n))
      , str ""
      , withAttr titleAttr $ str "The decisive mapping"
      , withAttr mapAttr $
          str
            ( "  " <> showNodeID (rnOriginalID n)
           <> "  ──▶  "
           <> showNodeIndex (rnIndex n)
            )
      , str ""
      , withAttr titleAttr $ str "Inputs (dense)"
      , vBox $
          case rnInputs n of
            []   -> [str "  (none)"]
            inps ->
              [ str ("  :" <> show i <> " ← " <> fmtRtInput inp)
              | (i, inp) <- zip [0 :: Int ..] inps
              ]
      , str ""
      , withAttr titleAttr $ str "Controls"
      , str ("  " <> show (rnControls n))
      , str ""
      , withAttr titleAttr $ str "Feeds into"
      , vBox $
          case consumers of
            [] -> [str "  (terminal node)"]
            cs ->
              [ str ("  → [" <> showNodeIndex cix <> "] :" <> show port)
              | (cix, port) <- cs
              ]
      , str ""
      , case (ctIR ct, ctRegions ct) of
          (Just ir, Just rg) -> drawNodeHistory ir rg n
          _                  -> emptyWidget
      ]

rtConsumers :: [RuntimeNode] -> NodeIndex -> [(NodeIndex, Int)]
rtConsumers nodes nix =
  [ (rnIndex n, i)
  | n <- nodes
  , (i, RFrom src _) <- zip [0 :: Int ..] (rnInputs n)
  , src == nix
  ]

drawNodeHistory :: GraphIR -> RegionGraph -> RuntimeNode -> Widget Name
drawNodeHistory ir rg rn =
  let origID   = rnOriginalID rn
      irMap    = M.fromList [(irNodeID n, n) | n <- giNodes ir]
      irNode   = M.lookup origID irMap
      regionID = M.lookup origID (rgNodeMap rg)
  in
    withAttr helpAttr $
      vBox
        [ str "Compilation history:"
        , str ("  Source:  " <> showNodeID origID)
        , str ("  IR:      " <> maybe "?" (\n -> show (irKind n) <> " @ " <> show (irRate n)) irNode)
        , str ("  Region:  " <> maybe "?" showRegionID regionID)
        , str ("  Dense:   " <> showNodeIndex (rnIndex rn))
        ]

section :: String -> String -> Widget Name
section label val =
  withAttr titleAttr (str (label <> ": ")) <+> str val

drawStatusBar :: AppState -> Widget Name
drawStatusBar st =
  let ct    = st ^. asTrace
      stage = st ^. asStage
      n     = nodeCount ct stage
      pos
        | n <= 0    = "—"
        | otherwise = show (st ^. asSelected + 1) <> "/" <> show n
      pipelineBit =
        case ctFailedAt ct of
          Nothing -> "  ✓ all stages passed"
          Just s  -> "  ✗ failed at " <> stageLabel s
  in
    withAttr statusAttr $
      hBox
        [ str " ←/→ stage  ↑/↓ node  PgUp/PgDn faster  Home/End ends  1-5 jump  q quit"
        , fill ' '
        , str (pos <> pipelineBit <> " ")
        ]

moveSelectionBy :: Int -> EventM Name AppState ()
moveSelectionBy delta = do
  ct    <- use asTrace
  stage <- use asStage
  let n = nodeCount ct stage
  asSelected %= clampIndex n . (+ delta)

handleEvent :: BrickEvent Name () -> EventM Name AppState ()
handleEvent (VtyEvent (V.EvKey (V.KChar 'q') [])) = halt
handleEvent (VtyEvent (V.EvKey V.KEsc []))        = halt

handleEvent (VtyEvent (V.EvKey V.KRight [])) = do
  asStage %= \s -> if s == maxBound then minBound else succ s
  modify clampSelection

handleEvent (VtyEvent (V.EvKey V.KLeft [])) = do
  asStage %= \s -> if s == minBound then maxBound else pred s
  modify clampSelection

handleEvent (VtyEvent (V.EvKey (V.KChar c) []))
  | c >= '1' && c <= '5' = do
      let idx = fromEnum c - fromEnum '1'
      case safeIndex allStages idx of
        Nothing    -> pure ()
        Just stage -> asStage .= stage
      modify clampSelection

handleEvent (VtyEvent (V.EvKey V.KDown []))     = moveSelectionBy 1
handleEvent (VtyEvent (V.EvKey V.KUp []))       = moveSelectionBy (-1)
handleEvent (VtyEvent (V.EvKey V.KPageDown [])) = moveSelectionBy 10
handleEvent (VtyEvent (V.EvKey V.KPageUp []))   = moveSelectionBy (-10)

handleEvent (VtyEvent (V.EvKey V.KHome [])) =
  asSelected .= 0

handleEvent (VtyEvent (V.EvKey V.KEnd [])) = do
  ct    <- use asTrace
  stage <- use asStage
  asSelected .= max 0 (nodeCount ct stage - 1)

handleEvent _ =
  pure ()

headerAttr, tabAttr, tabSelAttr, tabDimAttr, tabFailAttr :: AttrName
helpAttr, titleAttr, nodeAttr, nodeSelAttr :: AttrName
statusAttr, errAttr, regionHdrAttr, mapAttr :: AttrName

headerAttr    = attrName "header"
tabAttr       = attrName "tab"
tabSelAttr    = attrName "tabSel"
tabDimAttr    = attrName "tabDim"
tabFailAttr   = attrName "tabFail"
helpAttr      = attrName "help"
titleAttr     = attrName "title"
nodeAttr      = attrName "node"
nodeSelAttr   = attrName "nodeSel"
statusAttr    = attrName "status"
errAttr       = attrName "err"
regionHdrAttr = attrName "regionHdr"
mapAttr       = attrName "map"

theMap :: AttrMap
theMap = attrMap V.defAttr
  [ (headerAttr,    fg V.white `V.withStyle` V.bold)
  , (tabAttr,       fg (V.rgbColor (160 :: Int) 160 180))
  , (tabSelAttr,    V.black `on` V.rgbColor (140 :: Int) 140 220)
  , (tabDimAttr,    fg (V.rgbColor (70 :: Int) 70 80))
  , (tabFailAttr,   fg (V.rgbColor (255 :: Int) 120 120) `V.withStyle` V.bold)
  , (helpAttr,      fg (V.rgbColor (100 :: Int) 100 110))
  , (titleAttr,     fg (V.rgbColor (140 :: Int) 180 220) `V.withStyle` V.bold)
  , (nodeAttr,      fg (V.rgbColor (180 :: Int) 190 200))
  , (nodeSelAttr,   V.rgbColor (20 :: Int) 20 30 `on` V.rgbColor (80 :: Int) 80 160)
  , (statusAttr,    V.rgbColor (200 :: Int) 200 200 `on` V.rgbColor (40 :: Int) 40 60)
  , (errAttr,       fg (V.rgbColor (255 :: Int) 100 100))
  , (regionHdrAttr, fg (V.rgbColor (100 :: Int) 200 120) `V.withStyle` V.bold)
  , (mapAttr,       fg (V.rgbColor (255 :: Int) 200 100) `V.withStyle` V.bold)
  ]

app :: App AppState () Name
app = App
  { appDraw         = drawUI
  , appChooseCursor = neverShowCursor
  , appHandleEvent  = handleEvent
  , appStartEvent   = pure ()
  , appAttrMap      = const theMap
  }
