{-# LANGUAGE OverloadedStrings, OverloadedLabels #-}
module Editor.GraphEditor(
  startGUI
)where

-- Gtk modules
import qualified GI.Gtk as Gtk
import qualified GI.Gdk as Gdk
import qualified GI.Pango as P
import Data.GI.Base
import Data.GI.Base.GValue
import Data.GI.Base.GType
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Zip
import Data.IORef
import Graphics.Rendering.Cairo
import Graphics.Rendering.Pango.Layout
import Graphics.Rendering.Pango

import Data.List
import Data.Int
import Data.Char
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Tree as Tree
import Data.Monoid

-- verigraph modules
import Abstract.Category
import Abstract.Rewriting.DPO
import Data.Graphs hiding (null, empty)
import qualified Data.Graphs as G
import qualified Data.Graphs.Morphism as Morph
import qualified Data.TypedGraph as TG
import qualified Data.TypedGraph.Morphism as TGM
import qualified Data.Relation as R




-- editor modules
import Editor.Data.GraphicalInfo
import Editor.Data.Info
import Editor.Data.DiaGraph hiding (empty)
import Editor.Data.EditorState
import Editor.Render.Render
import Editor.Render.GraphDraw
import Editor.GraphEditor.UIBuilders
import qualified Editor.Data.DiaGraph as DG
import Editor.GraphEditor.SaveLoad
import Editor.GraphEditor.GrammarMaker
import Editor.GraphEditor.RuleViewer
import Editor.Helper.Helper
import Editor.Helper.Geometry
import Editor.Helper.GraphValidation
import Editor.GraphEditor.UpdateInspector
--------------------------------------------------------------------------------
-- MODULE STRUCTURES -----------------------------------------------------------
--------------------------------------------------------------------------------
{- |GraphStore
 A tuple representing what is showed in each node of the tree in the treeview
 It contains the informations:
 * name,
 * graph changed (0 - no, 1 - yes),
 * graph id,
 * type (0 - topic, 1 - typeGraph, 2 - hostGraph, 3 - ruleGraph, 4 - NAC) and
 * active (valid for rules only)
 * valid (if the current graph is correctly mapped to the typegraph)
-}
type GraphStore = (String, Int32, Int32, Int32, Bool, Bool)
type MergeMapping = (M.Map NodeId NodeId, M.Map EdgeId EdgeId)
type InjectionMapping = (M.Map NodeId NodeId, M.Map EdgeId EdgeId)

--------------------------------------------------------------------------------
-- FUNCTIONS ------------------------------------------------------------
--------------------------------------------------------------------------------

-- startGUI
-- creates the Graphical User Interface using the UIBuilders module and do the bindings
startGUI :: IO()
startGUI = do
  -- init GTK
  Gtk.init Nothing

  ------------------------------------------------------------------------------
  -- GUI definition ------------------------------------------------------------
  -- auxiliar windows ---------------------------------------------------------------
  helpWindow <- buildHelpWindow
  (rvWindow, rvNameLabel, rvlCanvas, rvrCanvas, rvlesIOR, rvresIOR, rvtgIOR, rvkIOR) <- createRuleViewerWindow

  -- main window ---------------------------------------------------------------
  -- creates the main window, containing the canvas and the slots to place the panels
  -- shows the main window
  (window, canvas, mainBox, treeFrame, inspectorFrame, fileItems, editItems, viewItems, helpItems) <- buildMainWindow
  let (newm,opn,svn,sva,eggx,svg,opg) = fileItems
      (del,udo,rdo,cpy,pst,cut,sla,sln,sle) = editItems
      (zin,zut,z50,zdf,z150,z200,vdf,orv) = viewItems
      (hlp,abt) = helpItems
  Gtk.widgetSetSensitive orv False
  -- creates the tree panel
  (treeBox, treeview, changesRenderer, nameRenderer, activeRenderer, createRBtn, removeRBtn, createNBtn, removeNBtn) <- buildTreePanel
  Gtk.containerAdd treeFrame treeBox
  -- creates the inspector panel and add to the window

  (typeInspBox, typeNameBox, colorBtn, lineColorBtn, radioShapes, radioStyles, tPropBoxes) <- buildTypeInspector

  nameEntry <- new Gtk.Entry []
  Gtk.widgetSetCanFocus nameEntry True
  Gtk.boxPackStart typeNameBox nameEntry True True 0

  Gtk.containerAdd inspectorFrame typeInspBox
  let
    typeInspWidgets = (nameEntry, colorBtn, lineColorBtn, radioShapes, radioStyles)
    [radioCircle, radioRect, radioSquare] = radioShapes
    [radioNormal, radioPointed, radioSlashed] = radioStyles

  (hostInspBox, hostNameBox, autoLabelN, autoLabelE, nodeTCBox, edgeTCBox, hostInspBoxes) <- buildHostInspector
  (ruleInspBox, ruleNameBox, autoLabelNR, autoLabelER, nodeTCBoxR, edgeTCBoxR, operationCBox, ruleInspBoxes) <- buildRuleInspector
  let
    hostInspWidgets = (nameEntry, nodeTCBox, edgeTCBox)
    ruleInspWidgets = (nameEntry, nodeTCBoxR, edgeTCBoxR, operationCBox)

  -- (rvwindow, lhsCanvas, rhsCanvas) <- buildRuleViewWindow window

  #showAll window

  -- init an model to display in the tree panel --------------------------------
  store <- Gtk.treeStoreNew [gtypeString, gtypeInt, gtypeInt, gtypeInt, gtypeBoolean, gtypeBoolean]
  Gtk.treeViewSetModel treeview (Just store)
  initStore store treeview

  changesCol <- Gtk.treeViewGetColumn treeview 0
  namesCol <- Gtk.treeViewGetColumn treeview 1
  activeCol <- Gtk.treeViewGetColumn treeview 2

  case changesCol of
    Nothing -> return ()
    Just col -> Gtk.treeViewColumnSetCellDataFunc col changesRenderer $ Just (\column renderer model iter -> do
      changed <- Gtk.treeModelGetValue model iter 1 >>= fromGValue:: IO Int32
      valid <- Gtk.treeModelGetValue model iter 5 >>= fromGValue :: IO Bool
      renderer' <- castTo Gtk.CellRendererText renderer
      case (renderer', changed, valid) of
        (Just r, 0, True)  -> set r [#text := ""  ]
        (Just r, 1, True)  -> set r [#text := "*" ]
        (Just r, 0, False) -> set r [#text := "!" ]
        (Just r, 1, False) -> set r [#text := "!*"]
        _ -> return ()

      )

  case namesCol of
    Nothing -> return ()
    Just col -> do
      #addAttribute col nameRenderer "text" 0
      path <- Gtk.treePathNewFromIndices [0,0]
      Gtk.treeViewExpandToPath treeview path
      Gtk.treeViewSetCursor treeview path (Nothing :: Maybe Gtk.TreeViewColumn) False

  case activeCol of
    Nothing -> return ()
    Just col -> Gtk.treeViewColumnSetCellDataFunc col activeRenderer $ Just (\column renderer model iter -> do
      gType <- Gtk.treeModelGetValue model iter 3 >>= \gv -> (fromGValue gv :: IO Int32)
      active <- Gtk.treeModelGetValue model iter 4 >>= \gv -> (fromGValue gv :: IO Bool)
      renderer' <- castTo Gtk.CellRendererToggle renderer
      case (renderer', gType) of
        (Just r, 3) -> set r [#visible := True, #radio := False, #active := active, #activatable:=True]
        (Just r, _) -> set r [#visible := False]
        _ -> return ()
      )

  ------------------------------------------------------------------------------
  -- init the editor variables  ------------------------------------------------
  st              <- newIORef emptyES -- actual state: all the necessary info to draw the graph
  oldPoint        <- newIORef (0.0,0.0) -- last point where a mouse button was pressed
  squareSelection <- newIORef Nothing -- selection box : Maybe (x,y,w,h)
  undoStack       <- newIORef ([] :: [DiaGraph])
  redoStack       <- newIORef ([] :: [DiaGraph])
  movingGI        <- newIORef False -- if the user started moving some object - necessary to add a position to the undoStack
  clipboard       <- newIORef DG.empty -- clipboard - DiaGraph
  fileName        <- newIORef (Nothing :: Maybe String) -- name of the opened file
  currentPath     <- newIORef [0] -- indices of path to current graph being edited
  currentGraph    <- newIORef 0 -- indice of the current graph being edited
  graphStates     <- newIORef $ M.fromList [(0, (emptyES,[],[])), (1, (emptyES, [], [])), (2, (emptyES, [], []))] -- map of states foreach graph in the editor
  changedProject  <- newIORef False -- set this flag as True when the graph is changed somehow
  changedGraph    <- newIORef [False] -- when modify a graph, set the flag in the 'currentGraph' to True
  lastSavedState  <- newIORef (M.empty :: M.Map Int32 DiaGraph)
  currentGraphType <- newIORef 1

  -- variables to specify graphs
  currentShape    <- newIORef NCircle -- the shape that all new nodes must have
  currentStyle    <- newIORef ENormal -- the style that all new edges must have
  currentC        <- newIORef (1,1,1) -- the color to init new nodes
  currentLC       <- newIORef (0,0,0) -- the color to init new edges and the line and text of new nodes

  -- variables to specify hostGraphs
  possibleNodeTypes   <- newIORef ( M.empty :: M.Map String (NodeGI, Int32)) -- possible types that a node can have in a hostGraph. Each node type is identified by a string and specifies a pair with Graphical information and the position of the entry in the comboBox
  possibleEdgeTypes   <- newIORef ( M.empty :: M.Map String (EdgeGI, Int32)) -- similar to above.
  activeTypeGraph     <- newIORef G.empty  -- the connection information from the active typeGraph
  currentNodeType     <- newIORef Nothing
  currentEdgeType     <- newIORef Nothing

  -- variables to specify NACs
  -- Diagraph from the rule - togetter with lhs it make the editor state
  nacInfoMapIORef <- newIORef (M.empty :: M.Map Int32 (DiaGraph, MergeMapping, InjectionMapping))

  ------------------------------------------------------------------------------
  -- EVENT BINDINGS ------------------------------------------------------------
  -- event bindings for the canvas ---------------------------------------------
  -- drawing event
  on canvas #draw $ \context -> do
    es <- readIORef st
    sq <- readIORef squareSelection
    t <- readIORef currentGraphType
    case t of
      0 -> return ()
      1 -> renderWithContext context $ drawTypeGraph es sq
      2 -> do
        tg <- readIORef activeTypeGraph
        renderWithContext context $ drawHostGraph es sq tg
      3 -> do
        tg <- readIORef activeTypeGraph
        renderWithContext context $ drawRuleGraph es sq tg
      4 -> do
        tg <- readIORef activeTypeGraph
        renderWithContext context $ drawNACGraph es sq tg
      _ -> return ()
    return False

  -- auxiliar function to update the active type graph
  let updateTG = do
        curr <- readIORef currentGraph
        if curr /= 0 -- if the current graph is the active typeGraph, update
          then return ()
          else do
                updateActiveTG st activeTypeGraph possibleNodeTypes possibleEdgeTypes
                possibleNT <- readIORef possibleNodeTypes
                possibleET <- readIORef possibleEdgeTypes
                tg <- readIORef activeTypeGraph
                -- update the comboBoxes
                Gtk.comboBoxTextRemoveAll nodeTCBox
                Gtk.comboBoxTextRemoveAll edgeTCBox
                Gtk.comboBoxTextRemoveAll nodeTCBoxR
                Gtk.comboBoxTextRemoveAll edgeTCBoxR
                forM_ (M.keys possibleNT) $ \k -> do
                    Gtk.comboBoxTextAppendText nodeTCBox (T.pack k)
                    Gtk.comboBoxTextAppendText nodeTCBoxR (T.pack k)
                forM_ (M.keys possibleET) $ \k -> do
                    Gtk.comboBoxTextAppendText edgeTCBox (T.pack k)
                    Gtk.comboBoxTextAppendText edgeTCBoxR (T.pack k)

                -- update the valid flags
                states <- readIORef graphStates
                setValidFlags store tg states

  -- mouse button pressed on canvas
  on canvas #buttonPressEvent $ \eventButton -> do
    b <- get eventButton #button
    x <- get eventButton #x
    y <- get eventButton #y
    ms <- get eventButton #state
    click <- get eventButton #type
    es <- readIORef st
    gType <- readIORef currentGraphType
    let z = editorGetZoom es
        (px,py) = editorGetPan es
        (x',y') = (x/z - px, y/z - py)
    liftIO $ do
      writeIORef oldPoint (x',y')
      Gtk.widgetGrabFocus canvas
      case (b, click == Gdk.EventType2buttonPress) of
        --double click with left button : rename selection
        (1, True) -> do
          let (n,e) = editorGetSelected es
          if null n && null e
            then return ()
            else liftIO $ Gtk.widgetGrabFocus nameEntry
        -- left button: select nodes and edges
        (1, False)  -> liftIO $ do
          let (oldSN,oldSE) = editorGetSelected es
              graph = editorGetGraph es
              gi = editorGetGI es
              sNode = case selectNodeInPosition gi (x',y') of
                Nothing -> []
                Just nid -> [nid]
              sEdge = case selectEdgeInPosition graph gi (x',y') of
                  Nothing -> []
                  Just eid -> [eid]
          -- add/remove elements of selection
          case (sNode, sEdge, Gdk.ModifierTypeShiftMask `elem` ms, Gdk.ModifierTypeControlMask `elem` ms) of
            -- clicked in blank space with Shift not pressed
            ([], [], False, _) -> do
              modifyIORef st (editorSetSelected ([],[]))
              writeIORef squareSelection $ Just (x',y',0,0)
            -- selected nodes or edges with shift pressed:
            (n, e, False, _) -> do
              let nS = if null n then False else n!!0 `elem` oldSN
                  eS = if null e then False else e!!0 `elem` oldSE
              if nS || eS
              then return ()
              else modifyIORef st (editorSetSelected (n, e))
            -- selected nodes or edges with Shift pressed -> add to selection
            (n, e, True, False) -> do
              let jointSN = foldl (\ns n -> if n `notElem` ns then n:ns else ns) [] $ sNode ++ oldSN
                  jointSE = foldl (\ns n -> if n `notElem` ns then n:ns else ns) [] $ sEdge ++ oldSE
              modifyIORef st (editorSetGraph graph . editorSetSelected (jointSN,jointSE))
            -- selected nodes or edges with Shift + Ctrl pressed -> remove from selection
            (n, e, True, True) -> do
              let jointSN = if null n then oldSN else delete (n!!0) oldSN
                  jointSE = if null e then oldSE else delete (e!!0) oldSE
              modifyIORef st (editorSetGraph graph . editorSetSelected (jointSN,jointSE))
          Gtk.widgetQueueDraw canvas
          updateTypeInspector st currentC currentLC typeInspWidgets tPropBoxes
          case gType of
            2 -> updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
            3 -> updateRuleInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType ruleInspWidgets ruleInspBoxes
            4 -> updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
            _ -> return ()
        -- right button click: create nodes and insert edges
        (3, False) -> liftIO $ do
          let g = editorGetGraph es
              gi = editorGetGI es
              dstNode = selectNodeInPosition gi (x',y')
          context <- Gtk.widgetGetPangoContext canvas
          stackUndo undoStack redoStack es
          cShape <- readIORef currentShape
          cColor <- readIORef currentC
          cLColor <- readIORef currentLC
          case (dstNode) of
            -- no selected node: create node
            Nothing -> case gType of
                0 -> return ()
                1 -> do
                  createNode' st "" True (x',y') cShape cColor cLColor context
                  setChangeFlags window store changedProject changedGraph currentPath currentGraph True
                  updateTG
                _ -> do
                  auto <- Gtk.toggleButtonGetActive autoLabelN
                  mntype <- readIORef currentNodeType
                  (t, shape, c, lc) <- case mntype of
                    Nothing -> return ("", cShape, cColor, cLColor)
                    Just t -> do
                      possibleNT <- readIORef possibleNodeTypes
                      let possibleNT' = M.map (\(gi,i) -> gi) possibleNT
                          mngi = M.lookup t possibleNT'
                      case mngi of
                        Nothing -> return ("", cShape, cColor, cLColor)
                        Just gi -> return (t, shape gi, fillColor gi, lineColor gi)
                  createNode' st (infoSetType "" t) auto (x',y') shape c lc context
                  setChangeFlags window store changedProject changedGraph currentPath currentGraph True
                  setCurrentValidFlag store st activeTypeGraph currentPath


            -- one node selected: create edges targeting this node
            Just nid -> case gType of
              0 -> return ()
              1 -> do
                estyle <- readIORef currentStyle
                color <- readIORef currentLC
                modifyIORef st (\es -> createEdges es nid "" True estyle color)
                setChangeFlags window store changedProject changedGraph currentPath currentGraph True
                updateTG
              _ -> do
                metype <- readIORef currentEdgeType
                cEstyle <- readIORef currentStyle
                cColor <- readIORef currentLC
                auto <- Gtk.toggleButtonGetActive autoLabelE
                (t,estyle,color) <- case metype of
                  Nothing -> return ("", cEstyle, cColor)
                  Just t -> do
                    pet <- readIORef possibleEdgeTypes
                    let pet' = M.map (\(gi,i) -> gi) pet
                        megi = M.lookup t pet'
                    case megi of
                      Nothing -> return ("", cEstyle, cColor)
                      Just gi -> return (t, style gi, color gi)
                modifyIORef st (\es -> createEdges es nid (infoSetType "" t) auto estyle color)
                setChangeFlags window store changedProject changedGraph currentPath currentGraph True
                setCurrentValidFlag store st activeTypeGraph currentPath

          Gtk.widgetQueueDraw canvas
          updateTypeInspector st currentC currentLC typeInspWidgets tPropBoxes
          case gType of
            2 -> updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
            3 -> updateRuleInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType ruleInspWidgets ruleInspBoxes
            4 -> updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
            _ -> return ()
        _           -> return ()
      return True

  -- mouse motion on canvas
  on canvas #motionNotifyEvent $ \eventMotion -> do
    ms <- get eventMotion #state
    x <- get eventMotion #x
    y <- get eventMotion #y
    (ox,oy) <- liftIO $ readIORef oldPoint
    es <- liftIO $ readIORef st
    let leftButton = Gdk.ModifierTypeButton1Mask `elem` ms
        -- in case of the editor being used in a notebook or with a mouse with just two buttons, ctrl + right button can be used instead of the middle button.
        middleButton = Gdk.ModifierTypeButton2Mask `elem` ms || Gdk.ModifierTypeButton3Mask `elem` ms && Gdk.ModifierTypeControlMask `elem` ms
        (sNodes, sEdges) = editorGetSelected es
        z = editorGetZoom es
        (px,py) = editorGetPan es
        (x',y') = (x/z - px, y/z - py)
    case (leftButton, middleButton, sNodes, sEdges) of
      -- if left button is pressed and no node is selected, update square selection
      (True, False, [], []) -> liftIO $ do
        modifyIORef squareSelection $ liftM $ (\(a,b,c,d) -> (a,b,x'-a,y'-b))
        sq <- readIORef squareSelection
        Gtk.widgetQueueDraw canvas
      -- if left button is pressed with some elements selected, then move them
      (True, False, n, e) -> liftIO $ do
        modifyIORef st (\es -> moveNodes es (ox,oy) (x',y'))
        modifyIORef st (\es -> if (>0) . length . fst . editorGetSelected $ es then es else moveEdges es (ox,oy) (x',y'))
        writeIORef oldPoint (x',y')
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        mv <- readIORef movingGI
        if not mv
          then do
            writeIORef movingGI True
            stackUndo undoStack redoStack es
          else return ()
        Gtk.widgetQueueDraw canvas
      -- if middle button is pressed, then move the view
      (False ,True, _, _) -> liftIO $ do
        let (dx,dy) = (x'-ox,y'-oy)
        modifyIORef st (editorSetPan (px+dx, py+dy))
        Gtk.widgetQueueDraw canvas
      _ -> return ()
    return True

  -- mouse button release on canvas
  on canvas #buttonReleaseEvent $ \eventButton -> do
    b <- get eventButton #button
    gType <- readIORef currentGraphType
    case b of
      1 -> liftIO $ do
        writeIORef movingGI False
        es <- readIORef st
        sq <- readIORef squareSelection
        let (n,e) = editorGetSelected es
        case (editorGetSelected es,sq) of
          -- if release the left button when there's a square selection,
          -- select the elements that are inside the selection
          (([],[]), Just (x,y,w,h)) -> do
            let graph = editorGetGraph es
                (ngiM, egiM) = editorGetGI es
                sNodes = map NodeId $ M.keys $
                                      M.filter (\ngi -> let pos = position ngi
                                                        in pointInsideRectangle pos (x + (w/2), y + (h/2), abs w, abs h)) ngiM
                sEdges = map edgeId $ filter (\e -> let pos = getEdgePosition graph (ngiM,egiM) e
                                                    in pointInsideRectangle pos (x + (w/2), y + (h/2), abs w, abs h)) $ edges graph
                newEs = editorSetSelected (sNodes, sEdges) $ es
            writeIORef st newEs
            updateTypeInspector st currentC currentLC typeInspWidgets tPropBoxes
            case gType of
              2 -> updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
              3 -> updateRuleInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType ruleInspWidgets ruleInspBoxes
              _ -> return ()
          ((n,e), Nothing) -> return ()
          _ -> return ()
      _ -> return ()
    liftIO $ do
      writeIORef squareSelection Nothing
      Gtk.widgetQueueDraw canvas
    return True

  -- mouse wheel scroll on canvas
  on canvas #scrollEvent $ \eventScroll -> do
    d <- get eventScroll #direction
    ms <- get eventScroll #state
    case (Gdk.ModifierTypeControlMask `elem` ms, d) of
      -- when control is pressed,
      -- if the direction is up, then zoom in
      (True, Gdk.ScrollDirectionUp)  -> liftIO $ Gtk.menuItemActivate zin
      -- if the direction is down, then zoom out
      (True, Gdk.ScrollDirectionDown) -> liftIO $ Gtk.menuItemActivate zut
      _ -> return ()
    return True

  -- keyboard
  on canvas #keyPressEvent $ \eventKey -> do
    k <- get eventKey #keyval >>= return . chr . fromIntegral
    ms <- get eventKey #state
    case (Gdk.ModifierTypeControlMask `elem` ms, Gdk.ModifierTypeShiftMask `elem` ms, toLower k) of
      -- F2 - rename selection
      (False,False,'\65471') -> Gtk.widgetGrabFocus nameEntry
      (True,False,'p') -> do -- Gtk.menuItemActivate orv
        es <- readIORef st
        print $ editorGetGraph es
      (False,False,'\65535') -> Gtk.menuItemActivate del
      (True,False,'m') -> do
        gtype <- readIORef currentGraphType
        if (gtype /= 4)
          then return ()
          else do
            gid <- readIORef currentGraph
            nacInfoMap <- readIORef nacInfoMapIORef
            es <- readIORef st
            let (snids, seids) = editorGetSelected es
                g = editorGetGraph es
                nodesFromLHS = filter (\n -> nodeId n `elem` snids && infoLocked (nodeInfo n)) (nodes g)
                edgesFromLHS = filter (\e -> edgeId e `elem` seids && infoLocked (edgeInfo e)) (edges g)
                nodesToMerge = filter (\n -> (infoType $ nodeInfo n) == (infoType $ nodeInfo $ head nodesFromLHS)) nodesFromLHS
                edgesToMerge = filter (\e -> (infoType $ edgeInfo e) == (infoType $ edgeInfo $ head edgesFromLHS)) edgesFromLHS
            if (length nodesToMerge < 2 && length edgesToMerge < 2)
              then return ()
              else do
                -- modify mapping to specify merging of nodes
                let (nacDG, (nM, eM), injectionM) = fromMaybe (DG.empty, (M.empty,M.empty), (M.empty,M.empty)) $ M.lookup gid nacInfoMap
                    -- genereate the merging map for nodes
                    nidsToMerge = map nodeId nodesToMerge
                    maxNID = if null nodesToMerge then NodeId 0 else maximum nidsToMerge
                    -- specify the merging in the map - having (2,3) and (3,3) means that the nodes 2 and 3 are merged
                    nPairs = foldr (\n nps -> (n,maxNID):nps) [] (map nodeId nodesToMerge)
                    nM' = foldr (\(a,b) m -> M.insert a b m) nM nPairs
                    -- extend the map so that the nodes that aren't in the lhs don't be deleted
                    nMExt = foldr (\nid m -> if nid `M.member` m then m else M.insert nid nid m) nM' (nodeIds g)

                -- modify mapping to specify merging of edges
                let eidsToMerge = map edgeId edgesToMerge
                    maxEID = if null edgesToMerge then EdgeId 0 else maximum eidsToMerge
                    -- update Ids of source and target nodes from edges that the user want to merge
                    edgesToMerge' = map (\e -> updateEdgeEndsIds e nM') edgesToMerge
                    -- check if the edges to merge have the same source and targets nodes
                    edgesToMerge'' = filter (\e -> sourceId e == sourceId (head edgesToMerge') && targetId e == targetId (head edgesToMerge')) edgesToMerge'
                    ePairs = foldr (\e eps -> (e,maxEID):eps) [] (map edgeId edgesToMerge'')
                    eM' = foldr (\(a,b) m -> M.insert a b m) eM ePairs
                    eMExt = foldr (\eid m -> if eid `M.member` m then m else M.insert eid eid m) eM' (edgeIds g)
                modifyIORef nacInfoMapIORef (M.insert gid (nacDG, (nMExt, eMExt), injectionM))
                -- join elements
                let g' = joinElementsFromMapping g (nMExt, eMExt)
                -- modify editor state
                modifyIORef st (editorSetGraph g' . editorSetSelected ([maxNID], [maxEID]))
                Gtk.widgetQueueDraw canvas
      (True,True,'m') -> do
        gtype <- readIORef currentGraphType
        if (gtype /= 4)
          then return ()
          else do
            -- reset mapping for selected elements
            gid <- readIORef currentGraph
            nacInfoMap <- readIORef nacInfoMapIORef
            es <- readIORef st
            let (snids, seids) = editorGetSelected es
                (nacDG, (nM,eM), (nI,eI)) = fromMaybe (DG.empty, (M.empty,M.empty), (M.empty,M.empty)) $ M.lookup gid nacInfoMap
                nM' = M.mapWithKey (\k a -> if a `elem` snids then k else a) nM
                eM' = M.mapWithKey (\k a -> if a `elem` seids then k else a) eM
            -- reload lhs
            path <- readIORef currentPath
            lhsdg <- getParentDiaGraph store path graphStates
            let ruleLGNodesLock = foldr (\n g -> G.updateNodePayload n g (\info -> infoSetLocked info True)) (fst lhsdg) (nodeIds . fst $ lhsdg)
                ruleLG = foldr (\e g -> G.updateEdgePayload e g (\info -> infoSetLocked info True)) ruleLGNodesLock (edgeIds . fst $ lhsdg)
                ruleLGI = snd lhsdg
                ruleLG' = joinElementsFromMapping ruleLG (nM',eM')
            -- remove the elements of lhs from the current graph
            let g = editorGetGraph es
                gi = editorGetGI es
                dg@(nacG,nacGI) = diagrSubtract (g,gi) (fst lhsdg,ruleLGI)
                nI' = M.fromList $ filter (\(a,b) -> a == b) $ mkpairs (nodeIds ruleLG) (nodeIds nacG)
                eI' = M.fromList $ filter (\(a,b) -> a == b) $ mkpairs (edgeIds ruleLG) (edgeIds nacG)
            -- glue NAC part into the LHS
            tg <- readIORef activeTypeGraph
            let (g',gi') = joinNAC (dg,(nM',eM'),(nI',eI')) (ruleLG', ruleLGI) tg
                g'' = splitNodesLabels g' nM'
            -- write editor State
            let newNids = M.keys $ M.filter (\a -> a `elem` snids) nM
                newEids = M.keys $ M.filter (\a -> a `elem` seids) eM
            modifyIORef nacInfoMapIORef (M.insert gid (dg, (nM',eM'),(nI',eI')))
            modifyIORef st (editorSetSelected (newNids, newEids) . editorSetGraph g'' . editorSetGI gi')
            Gtk.widgetQueueDraw canvas





      _ -> return ()
    return True

  -- event bindings for the menu toolbar ---------------------------------------
  -- auxiliar functions to create/open/save the project
      -- auxiliar function to prepare the treeStore to save
      -- auxiliar function, add the current editor state in the graphStates list
  let storeCurrentES = do es <- readIORef st
                          undo <- readIORef undoStack
                          redo <- readIORef redoStack
                          index <- readIORef currentGraph
                          modifyIORef graphStates $ M.insert index (es,undo,redo)

      -- auxiliar function to clean the flags after saving
  let afterSave = do  writeIORef changedProject False
                      states <- readIORef graphStates
                      writeIORef changedGraph (take (length states) (repeat False))
                      writeIORef lastSavedState (M.map (\(es,_,_) -> (editorGetGraph es, editorGetGI es)) states)
                      gvChanged <- toGValue (0::Int32)
                      Gtk.treeModelForeach store $ \model path iter -> do
                        Gtk.treeStoreSetValue store iter 1 gvChanged
                        return False
                      indicateProjChanged window False
                      updateSavedState lastSavedState graphStates
                      filename <- readIORef fileName
                      case filename of
                        Nothing -> set window [#title := "Verigraph-GUI"]
                        Just fn -> set window [#title := T.pack ("Verigraph-GUI - " ++ fn)]

  -- auxiliar function to check if the project was changed
  -- it does the checking and if no, ask the user if them want to save.
  -- returns True if there's no changes, if the user don't wanted to save or if he wanted and the save operation was successfull
  -- returns False if the user wanted to save and the save operation failed or opted to cancel.
  let confirmOperation = do changed <- readIORef changedProject
                            response <- if changed
                              then createConfirmDialog window "The project was changed, do you want to save?"
                              else return Gtk.ResponseTypeNo
                            case response of
                              Gtk.ResponseTypeCancel -> return False
                              r -> case r of
                                Gtk.ResponseTypeNo -> return True
                                Gtk.ResponseTypeYes -> do
                                  storeCurrentES
                                  structs <- getStructsToSave store graphStates
                                  saveFile structs saveProject fileName window True -- returns True if saved the file

  -- new project action activated
  on newm #activate $ do
    continue <- confirmOperation
    if continue
      then do
        Gtk.treeStoreClear store
        initStore store treeview
        writeIORef st emptyES
        writeIORef undoStack []
        writeIORef redoStack []
        writeIORef fileName Nothing
        writeIORef currentPath [0]
        writeIORef currentGraphType 1
        writeIORef currentGraph 0
        writeIORef graphStates $ M.fromList [(0, (emptyES,[],[])), (1, (emptyES, [], [])), (2, (emptyES, [], []))]
        writeIORef lastSavedState M.empty
        writeIORef changedProject False
        writeIORef changedGraph [False]
        set window [#title := "Verigraph-GUI"]
        Gtk.widgetQueueDraw canvas
      else return ()



  --open project
  on opn #activate $ do
    continue <- confirmOperation
    if continue
      then do
        mg <- loadFile window loadProject
        case mg of
          Nothing -> return ()
          Just (forest,fn) -> do
                Gtk.treeStoreClear store
                let emptyGSt = (emptyES, [], [])
                let toGSandStates n i = case n of
                              Topic name -> ((name,0,0,0,False), (0,(i,emptyGSt)))
                              TypeGraph name es -> ((name,0,i,1,True), (1, (i,(es,[],[]))))
                              HostGraph name es -> ((name,0,i,2,True), (2, (i,(es,[],[]))))
                              RuleGraph name es a -> ((name,0,i,3,a), (3, (i,(es,[],[]))))
                    idForest = genForestIds forest 0
                    infoForest = zipWith (mzipWith toGSandStates) forest idForest
                    nameForest = map (fmap fst) infoForest
                    statesForest = map (fmap snd) infoForest
                    statesList = map snd . filter (\st -> fst st /= 0) . concat . map Tree.flatten $ statesForest

                let putInStore (Tree.Node (name,c,i,t,a) fs) mparent =
                        case t of
                          0 -> do iter <- Gtk.treeStoreAppend store mparent
                                  storeSetGraphStore store iter (name,c,i,t,a,True)
                                  mapM (\n -> putInStore n (Just iter)) fs
                                  return ()
                          _ -> do iter <- Gtk.treeStoreAppend store mparent
                                  storeSetGraphStore store iter (name,c,i,t,a,True)
                                  return ()
                mapM (\n -> putInStore n Nothing) nameForest
                let (i,(es, _,_)) = if length statesList > 0 then statesList!!0 else (0,(emptyES,[],[]))
                writeIORef st es
                writeIORef undoStack []
                writeIORef redoStack []
                writeIORef graphStates $ M.fromList statesList
                writeIORef fileName $ Just fn
                writeIORef currentGraph i
                writeIORef currentPath [0]
                writeIORef currentGraphType 1
                p <- Gtk.treePathNewFromIndices [0]
                Gtk.treeViewExpandToPath treeview p
                Gtk.treeViewSetCursor treeview p namesCol False
                afterSave
                updateTG
                Gtk.widgetQueueDraw canvas
      else return ()

  -- save project
  on svn #activate $ do
    storeCurrentES
    structs <- getStructsToSave store graphStates
    saved <- saveFile structs saveProject fileName window True
    if saved
      then do afterSave
      else return ()

  -- save project as
  sva `on` #activate $ do
    storeCurrentES
    structs <- getStructsToSave store graphStates
    saved <- saveFileAs structs saveProject fileName window True
    if saved
      then afterSave
      else return ()

  eggx `on` #activate $ do
    sts <- readIORef graphStates

    let (tes,_,_) = fromJust $ M.lookup 0 sts
        (hes,_,_) = fromJust $ M.lookup 1 sts
        tg = editorGetGraph tes
        hg = editorGetGraph hes

    rules <- getRules store graphStates
    let rulesNames = map snd rules
        rgs = map fst rules

    mfstOrderGG <- makeGrammar tg hg rgs rulesNames
    case mfstOrderGG of
      Nothing -> showError window "No first-order productions were found, at least one is needed."
      Just fstOrderGG -> do
        saveFileAs (fstOrderGG,tg) exportGGX fileName window False
        return ()

  -- open graph
  on opg #activate $ do
    mg <- loadFile window loadGraph
    case mg of
      Just ((g,gi),path) -> do
        let splitAtToken str tkn = splitAt (1 + (fromMaybe (-1) $ findIndex (==tkn) str)) str
            getLastPart str = let splited = (splitAtToken str '/') in if fst splited == "" then str else getLastPart (snd splited)
            getName str = if (tails str)!!(length str - 3) == ".gr" then take (length str - 3) str else str
        -- add the loaded diagraph to the graphStates
        newKey <- readIORef graphStates >>= return . (+1) . maximum . M.keys
        modifyIORef graphStates $ M.insert newKey (editorSetGI gi . editorSetGraph g $ emptyES, [],[])
        -- update the treeview
        (valid,parentIter) <- Gtk.treeModelIterNthChild store Nothing 2
        if not valid
          then return ()
          else do
            iter <- Gtk.treeStoreAppend store (Just parentIter)
            let valid = True -- check if the graph is valid according to the typeGraph
            storeSetGraphStore store iter (getName . getLastPart $ path, 2, newKey, 2, True, valid)
            path <- Gtk.treeModelGetPath store iter
            Gtk.treeViewExpandToPath treeview path
            Gtk.treeViewSetCursor treeview path (Nothing :: Maybe Gtk.TreeViewColumn) False
            -- update the IORefs
            pathIndices <- Gtk.treePathGetIndices path >>= return . fromJust
            writeIORef currentPath pathIndices
            writeIORef currentGraph newKey
            modifyIORef changedGraph (\xs -> xs ++ [True])
            writeIORef changedProject True
            indicateProjChanged window True
            Gtk.widgetQueueDraw canvas
      _      -> return ()

  -- save graph
  on svg #activate $ do
    es <- readIORef st
    let g  = editorGetGraph es
        gi = editorGetGI es
    saveFileAs (g,gi) saveGraph fileName window False
    return ()

  let updateByType = do
        gt <- readIORef currentGraphType
        case gt of
          1 -> updateTG
          2 -> setCurrentValidFlag store st activeTypeGraph currentPath
          3 -> setCurrentValidFlag store st activeTypeGraph currentPath
          _ -> return ()

  -- delete item
  on del #activate $ do
    es <- readIORef st
    stackUndo undoStack redoStack es
    modifyIORef st (\es -> deleteSelected es)
    setChangeFlags window store changedProject changedGraph currentPath currentGraph True
    updateByType
    Gtk.widgetQueueDraw canvas


  -- undo
  on udo #activate $ do
    applyUndo undoStack redoStack st
    -- indicate changes
    sst <- readIORef lastSavedState
    index <- readIORef currentGraph
    es <- readIORef st
    let (g,gi) = (editorGetGraph es, editorGetGI es)
        x = case M.lookup (fromIntegral index) $ sst of
              Just diag -> diag
              Nothing -> DG.empty
    setChangeFlags window store changedProject changedGraph currentPath currentGraph $ not (isDiaGraphEqual (g,gi) x)
    Gtk.widgetQueueDraw canvas
    updateByType

  -- redo
  on rdo #activate $ do
    applyRedo undoStack redoStack st
    -- indicate changes
    sst <- readIORef lastSavedState
    index <- readIORef currentGraph
    es <- readIORef st
    let (g,gi) = (editorGetGraph es, editorGetGI es)
        x = case M.lookup (fromIntegral index) $ sst of
              Just diag -> diag
              Nothing -> DG.empty
    setChangeFlags window store changedProject changedGraph currentPath currentGraph $ not (isDiaGraphEqual (g,gi) x)
    Gtk.widgetQueueDraw canvas
    updateByType

  -- copy
  on cpy #activate $ do
    es <- readIORef st
    let copy = copySelected es
    writeIORef clipboard $ copy

  -- paste
  on pst #activate $ do
    es <- readIORef st
    clip <- readIORef clipboard
    stackUndo undoStack redoStack es
    setChangeFlags window store changedProject changedGraph currentPath currentGraph True
    modifyIORef st (pasteClipBoard clip)
    Gtk.widgetQueueDraw canvas
    updateByType

  -- cut
  on cut #activate $ do
    es <- readIORef st
    writeIORef clipboard $ copySelected es
    modifyIORef st (\es -> deleteSelected es)
    stackUndo undoStack redoStack es
    setChangeFlags window store changedProject changedGraph currentPath currentGraph  True
    Gtk.widgetQueueDraw canvas
    updateByType

  -- select all
  on sla #activate $ do
    modifyIORef st (\es -> let g = editorGetGraph es
                           in editorSetSelected (nodeIds g, edgeIds g) es)
    Gtk.widgetQueueDraw canvas

  -- select edges
  on sle #activate $ do
    es <- readIORef st
    let selected = editorGetSelected es
        g = editorGetGraph es
    case selected of
      ([],[]) -> writeIORef st $ editorSetSelected ([], edgeIds g) es
      ([], e) -> return ()
      (n,e) -> writeIORef st $ editorSetSelected ([],e) es
    Gtk.widgetQueueDraw canvas

  -- select nodes
  on sln #activate $ do
    es <- readIORef st
    let selected = editorGetSelected es
        g = editorGetGraph es
    case selected of
      ([],[]) -> writeIORef st $ editorSetSelected (nodeIds g, []) es
      (n, []) -> return ()
      (n,e) -> writeIORef st $ editorSetSelected (n,[]) es
    Gtk.widgetQueueDraw canvas

  -- zoom in
  zin `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom (editorGetZoom es * 1.1) es )
    Gtk.widgetQueueDraw canvas

  -- zoom out
  zut `on` #activate $ do
    modifyIORef st (\es -> let z = editorGetZoom es * 0.9 in if z >= 0.5 then editorSetZoom z es else es)
    Gtk.widgetQueueDraw canvas

  z50 `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom 0.5 es )
    Gtk.widgetQueueDraw canvas

  -- reset zoom to defaults
  zdf `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom 1.0 es )
    Gtk.widgetQueueDraw canvas

  z150 `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom 1.5 es )
    Gtk.widgetQueueDraw canvas

  z200 `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom 2.0 es )
    Gtk.widgetQueueDraw canvas

  -- reset view to defaults (reset zoom and pan)
  vdf `on` #activate $ do
    modifyIORef st (\es -> editorSetZoom 1 $ editorSetPan (0,0) es )
    Gtk.widgetQueueDraw canvas

  orv `on` #activate $ do
    gt <- readIORef currentGraphType
    if gt == 3
      then do
        g <- readIORef st >>= \es -> return $ editorGetGraph es
        (lhs,k,rhs) <- return $ graphToRuleGraphs g

        gi <- readIORef st >>= return . editorGetGI
        tg <- readIORef activeTypeGraph

        --change the dimensions of each node
        context <- Gtk.widgetGetPangoContext canvas
        let changeGIDims str gi = do
               dims <- getStringDims str context Nothing
               gi' <- return $ nodeGiSetDims dims gi
               return gi'
        let updateNodesDims nodes = do
              nodeGiM' <- forM (nodes) (\n -> do
                    let nid = fromEnum . nodeId $ n
                        ngi = getNodeGI nid (fst gi)
                    gi' <- changeGIDims (infoLabel . nodeInfo $ n) ngi
                    return (nid, gi'))
              return $ M.fromList nodeGiM'
        nodesGiM <- updateNodesDims (nodes g)

        -- update the elements positions
        let selectedLhs = map (fromEnum . nodeId) $ nodes lhs
            selectedRhs = map (fromEnum . nodeId) $ nodes rhs
            nodesGiMLhs = M.filterWithKey (\k _ -> k `elem` selectedLhs) nodesGiM
            nodesGiMRhs = M.filterWithKey (\k _ -> k `elem` selectedRhs) nodesGiM
            getMinX gi = (fst $ position gi) - (maximum [fst $ dims gi, snd $ dims gi])
            getMinY gi = (snd $ position gi) - (maximum [fst $ dims gi, snd $ dims gi])
            minXL = minimum $ map getMinX $ M.elems nodesGiMLhs
            minYL = minimum $ map getMinY $ M.elems nodesGiMLhs
            minXR = minimum $ map getMinX $ M.elems nodesGiMRhs
            minYR = minimum $ map getMinY $ M.elems nodesGiMRhs
            upd (x,y) (minX, minY) = (x-minX+20, y-minY+20)
            nodesGiML = M.map (\gi -> nodeGiSetPosition (upd (position gi) (minXL, minYL)) gi) nodesGiMLhs
            nodesGiMR = M.map (\gi -> nodeGiSetPosition (upd (position gi) (minXR, minYR)) gi) nodesGiMRhs

        -- get the name of the current rule
        path <- readIORef currentPath >>= Gtk.treePathNewFromIndices
        (valid, iter) <- Gtk.treeModelGetIter store path
        name <- if valid
                then Gtk.treeModelGetValue store iter 0 >>= (\n -> fromGValue n :: IO (Maybe String)) >>= return . T.pack . fromJust
                else return "ruleName should be here"

        writeIORef rvkIOR k
        modifyIORef rvlesIOR (editorSetGraph lhs . editorSetGI (nodesGiML, snd gi))
        modifyIORef rvresIOR (editorSetGraph rhs . editorSetGI (nodesGiMR, snd gi))
        Gtk.labelSetText rvNameLabel name
        writeIORef rvtgIOR tg

        Gtk.widgetQueueDraw rvlCanvas
        Gtk.widgetQueueDraw rvrCanvas

        #showAll rvWindow
      else return ()

  -- help
  hlp `on` #activate $ do
    #showAll helpWindow

  -- about
  abt `on` #activate $ buildAboutDialog




  -- event bindings -- inspector panel -----------------------------------------
  -- pressed a key when editing the nameEntry
  on nameEntry #keyPressEvent $ \eventKey -> do
    k <- get eventKey #keyval >>= return . chr . fromIntegral
    --if it's Return or Enter (Numpad), then change the name of the selected elements
    case k of
       '\65293' -> Gtk.widgetGrabFocus canvas
       '\65421' -> Gtk.widgetGrabFocus canvas
       _       -> return ()
    return False

  -- when the entry lose focus
  on nameEntry #focusOutEvent $ \event -> do
    es <- readIORef st
    stackUndo undoStack redoStack es
    setChangeFlags window store changedProject changedGraph currentPath currentGraph True
    name <- Gtk.entryGetText nameEntry >>= return . T.unpack
    context <- Gtk.widgetGetPangoContext canvas
    renameSelected st name context
    Gtk.widgetQueueDraw canvas
    updateHostInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType hostInspWidgets hostInspBoxes
    updateByType
    return False

  on autoLabelN #toggled $ do
    active <- Gtk.toggleButtonGetActive autoLabelN
    set autoLabelNR [#active := active]

  on autoLabelNR #toggled $ do
    active <- Gtk.toggleButtonGetActive autoLabelNR
    set autoLabelN [#active := active]

  on autoLabelE #toggled $ do
    active <- Gtk.toggleButtonGetActive autoLabelE
    set autoLabelER [#active := active]

  on autoLabelER #toggled $ do
    active <- Gtk.toggleButtonGetActive autoLabelER
    set autoLabelE [#active := active]


  -- select a fill color
  -- change the selection fill color and
  -- set the current fill color as the selected color
  on colorBtn #colorSet $ do
    gtkcolor <- Gtk.colorChooserGetRgba colorBtn
    es <- readIORef st
    r <- get gtkcolor #red
    g <- get gtkcolor #green
    b <- get gtkcolor #blue
    let color = (r,g,b)
        (nds,edgs) = editorGetSelected es
    writeIORef currentC color
    if null nds
      then return ()
      else do
        let (ngiM, egiM) = editorGetGI es
            newngiM = M.mapWithKey (\k ngi -> if NodeId k `elem` nds then nodeGiSetColor color ngi else ngi) ngiM
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> editorSetGI (newngiM, egiM) es)
        Gtk.widgetQueueDraw canvas
        updateTG

  -- select a line color
  -- same as above, except it's for the line color
  on lineColorBtn #colorSet $ do
    gtkcolor <- Gtk.colorChooserGetRgba lineColorBtn
    es <- readIORef st
    r <- get gtkcolor #red
    g <- get gtkcolor #green
    b <- get gtkcolor #blue
    let color = (r,g,b)
        (nds,edgs) = editorGetSelected es
    writeIORef currentLC color
    if null nds && null edgs
      then return ()
      else do
        let (ngiM, egiM) = editorGetGI es
            newngiM = M.mapWithKey (\k ngi -> if NodeId k `elem` nds then nodeGiSetLineColor color ngi else ngi) ngiM
            newegiM = M.mapWithKey (\k egi -> if EdgeId k `elem` edgs then edgeGiSetColor color egi else egi) egiM
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> editorSetGI (newngiM, newegiM) es)
        Gtk.widgetQueueDraw canvas
        updateTG

  -- toogle the radio buttons for node shapes
  -- change the shape of the selected nodes and set the current shape for new nodes
  radioCircle `on` #toggled $ do
    writeIORef currentShape NCircle
    es <- readIORef st
    active <- get radioCircle #active
    let nds = fst $ editorGetSelected es
        giM = fst $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> NodeId k `elem` nds && shape gi /= NCircle) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeNodeShape es NCircle)
        Gtk.widgetQueueDraw canvas
        updateTG

  radioRect `on` #toggled $ do
    writeIORef currentShape NRect
    es <- readIORef st
    active <- get radioRect #active
    let nds = fst $ editorGetSelected es
        giM = fst $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> NodeId k `elem` nds && shape gi /= NRect) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeNodeShape es NRect)
        Gtk.widgetQueueDraw canvas
        updateTG

  radioSquare `on` #toggled $ do
    writeIORef currentShape NSquare
    es <- readIORef st
    active <- get radioSquare #active
    let nds = fst $ editorGetSelected es
        giM = fst $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> NodeId k `elem` nds && shape gi /= NSquare) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeNodeShape es NSquare)
        Gtk.widgetQueueDraw canvas
        updateTG

  -- toogle the radio buttons for edge styles
  -- change the style of the selected edges and set the current style for new edges
  radioNormal `on` #toggled $ do
    writeIORef currentStyle ENormal
    es <- readIORef st
    active <- get radioNormal #active
    let edgs = snd $ editorGetSelected es
        giM = snd $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> EdgeId k `elem` edgs && style gi /= ENormal) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeEdgeStyle es ENormal)
        Gtk.widgetQueueDraw canvas
        updateTG

  radioPointed `on` #toggled $ do
    writeIORef currentStyle EPointed
    es <- readIORef st
    active <- get radioPointed #active
    let edgs = snd $ editorGetSelected es
        giM = snd $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> EdgeId k `elem` edgs && style gi /= EPointed) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeEdgeStyle es EPointed)
        Gtk.widgetQueueDraw canvas
        updateTG

  radioSlashed `on` #toggled $ do
    writeIORef currentStyle ESlashed
    es <- readIORef st
    active <- get radioSlashed #active
    let edgs = snd $ editorGetSelected es
        giM = snd $ editorGetGI es
    if not active || M.null (M.filterWithKey (\k gi -> EdgeId k `elem` edgs && style gi /= ESlashed) giM)
      then return ()
      else do
        stackUndo undoStack redoStack es
        setChangeFlags window store changedProject changedGraph currentPath currentGraph True
        modifyIORef st (\es -> changeEdgeStyle es ESlashed)
        Gtk.widgetQueueDraw canvas
        updateTG



  let nodeTCBoxChangedCallback comboBox= do
          t <- readIORef currentGraphType
          if t < 2
            then return ()
            else do
              index <- Gtk.comboBoxGetActive comboBox
              if index == (-1)
                then return ()
                else do
                  es <- readIORef st
                  typeInfo <- Gtk.comboBoxTextGetActiveText comboBox >>= return . T.unpack
                  typeGI <- readIORef possibleNodeTypes >>= return . fst . fromJust . M.lookup typeInfo
                  let (sNids,sEids) = editorGetSelected es
                      g = editorGetGraph es
                      giM = editorGetGI es
                      newGraph = foldl (\g nid -> updateNodePayload nid g (\info -> infoSetType info typeInfo)) g sNids
                      newNGI = foldl (\gi nid -> let ngi = getNodeGI (fromEnum nid) gi
                                                 in M.insert (fromEnum nid) (nodeGiSetPosition (position ngi) . nodeGiSetDims (dims ngi) $ typeGI) gi) (fst giM) sNids
                  writeIORef st (editorSetGI (newNGI, snd giM) . editorSetGraph newGraph $ es)
                  writeIORef currentNodeType $ Just typeInfo
                  Gtk.widgetQueueDraw canvas
                  setCurrentValidFlag store st activeTypeGraph currentPath

  -- choose a type in the type comboBox for nodes
  on nodeTCBox #changed $ nodeTCBoxChangedCallback nodeTCBox
  on nodeTCBoxR #changed $ nodeTCBoxChangedCallback nodeTCBoxR

  let edgeTCBoxCallback comboBox = do
          t <- readIORef currentGraphType
          if t < 2
            then return ()
            else do
              index <- Gtk.comboBoxGetActive comboBox
              if index == (-1)
                then return ()
                else do
                  es <- readIORef st
                  typeInfo <- Gtk.comboBoxTextGetActiveText comboBox >>= return . T.unpack
                  typeGI <- readIORef possibleEdgeTypes >>= return . fst . fromJust . M.lookup typeInfo
                  let (sNids,sEids) = editorGetSelected es
                      g = editorGetGraph es
                      giM = editorGetGI es
                      newEGI = foldl (\gi eid -> let egi = getEdgeGI (fromEnum eid) gi
                                                 in M.insert (fromEnum eid) (edgeGiSetPosition (cPosition egi) typeGI) gi) (snd giM) sEids
                      newGI = (fst giM, newEGI)
                      newGraph = foldl (\g eid -> updateEdgePayload eid g (\info -> infoSetType info typeInfo)) g sEids
                  writeIORef st (editorSetGI newGI . editorSetGraph newGraph $ es)
                  writeIORef currentEdgeType $ Just typeInfo
                  Gtk.widgetQueueDraw canvas
                  setCurrentValidFlag store st activeTypeGraph currentPath

  -- choose a type in the type comboBox for edges
  on edgeTCBox #changed $ edgeTCBoxCallback edgeTCBox
  on edgeTCBoxR #changed $ edgeTCBoxCallback edgeTCBoxR

  -- choose a operaion in the operation comboBox
  on operationCBox #changed $ do
    t <- readIORef currentGraphType
    if t < 3
      then return ()
      else do
        index <- Gtk.comboBoxGetActive operationCBox
        if index < 0 || index > 2
          then return ()
          else do
            es <- readIORef st
            operationInfo <- return $ case index of
              0 -> ""
              1 -> "new"
              2 -> "del"
            let (sNids,sEids) = editorGetSelected es
                g = editorGetGraph es
                gi = editorGetGI es
                newGraph  = foldl (\g nid -> updateNodePayload nid g (\info -> infoSetOperation info operationInfo)) g sNids
                newGraph' = foldl (\g eid -> updateEdgePayload eid g (\info -> infoSetOperation info operationInfo)) newGraph sEids
            context <- Gtk.widgetGetPangoContext canvas
            font <- case operationInfo == "" of
              True -> return Nothing
              False -> return $ Just "Sans Bold 10"
            ndims <- forM sNids $ \nid -> do
              dim <- getStringDims (infoVisible . nodeInfo . fromJust . G.lookupNode nid $ newGraph') context font
              return (nid, dim)
            let newNgiM = foldl (\giM (nid, dim) -> let gi = nodeGiSetDims dim $ getNodeGI (fromEnum nid) giM
                                                    in M.insert (fromEnum nid) gi giM) (fst gi) ndims
            writeIORef st (editorSetGI (newNgiM, snd gi) . editorSetGraph newGraph' $ es)
            updateRuleInspector st possibleNodeTypes possibleEdgeTypes currentNodeType currentEdgeType ruleInspWidgets ruleInspBoxes
            Gtk.widgetQueueDraw canvas

  -- event bindings for the graphs' tree ---------------------------------------
  -- changed the selected graph
  let changeInspector inspectorBox nameBox = do
        child <- Gtk.containerGetChildren inspectorFrame >>= \a -> return (a!!0)
        Gtk.containerRemove inspectorFrame child
        Gtk.containerAdd inspectorFrame inspectorBox
        entryParent <- Gtk.widgetGetParent nameEntry
        case entryParent of
          Nothing -> return ()
          Just parent -> do
            mp <- castTo Gtk.Box parent
            case mp of
              Nothing -> return ()
              Just p -> Gtk.containerRemove p nameEntry
        Gtk.boxPackStart nameBox nameEntry True True 0
        #showAll inspectorFrame

  on treeview #cursorChanged $ do
    selection <- Gtk.treeViewGetSelection treeview
    (sel,model,iter) <- Gtk.treeSelectionGetSelected selection
    case sel of
      False -> return ()
      True -> do
        -- get the current path for update
        path <- Gtk.treeModelGetPath model iter >>= Gtk.treePathGetIndices >>= return . fromMaybe [0]
        -- compare the selected graph with the current one
        cIndex <- readIORef currentGraph
        cGType <- readIORef currentGraphType
        index <- Gtk.treeModelGetValue model iter 2 >>= fromGValue  :: IO Int32
        gType <- Gtk.treeModelGetValue model iter 3 >>= fromGValue  :: IO Int32

        -- if current graph is a nac, remove lhs part, letting only a piece that will be glued togetter
        case cGType of
          4 -> do
            nacInfoMap <- readIORef nacInfoMapIORef
            pathIndices <- readIORef currentPath
            (lhs,lhsGI) <- getParentDiaGraph store pathIndices graphStates
            es <- readIORef st
            let (diag,mergeMapping,_) = fromMaybe (DG.empty, (M.empty,M.empty), (M.empty, M.empty)) $ M.lookup cIndex nacInfoMap
                g = editorGetGraph es
                gi = editorGetGI es
                dg@(nacG,nacGI) = diagrSubtract (g,gi) (lhs,lhsGI)
                nodeM = M.fromList $ filter (\(a,b) -> a == b) $ mkpairs (nodeIds lhs) (nodeIds nacG)
                edgeM = M.fromList $ filter (\(a,b) -> a == b) $ mkpairs (edgeIds lhs) (edgeIds nacG)
            modifyIORef nacInfoMapIORef (M.insert cIndex (dg,mergeMapping,(nodeM,edgeM)))
          _ -> return ()

        -- change the graph
        case (cIndex == index, gType) of
          -- same graph
          (True, _)  -> do
            -- just update the current path
            writeIORef currentPath path
          (False, 0) -> return ()

          (False, 4) -> do
            -- update the current path
            writeIORef currentPath path
            -- update the current graph in the tree
            storeCurrentES
            -- build the graph for the nac
            writeIORef currentGraphType gType
            states <- readIORef graphStates
            let maybeState = M.lookup index states
            case maybeState of
              Just (es,u,r) -> do
                tg <- readIORef activeTypeGraph
                lhsdg <- getParentDiaGraph store path graphStates
                nacInfoMap <- readIORef nacInfoMapIORef
                let ruleLGNodesLock = foldr (\n g -> G.updateNodePayload n g (\info -> infoSetLocked info True)) (fst lhsdg) (nodeIds . fst $ lhsdg)
                    ruleLG = foldr (\e g -> G.updateEdgePayload e g (\info -> infoSetLocked info True)) ruleLGNodesLock (edgeIds . fst $ lhsdg)
                    ruleLGI = snd lhsdg
                (nG,gi) <- case M.lookup index $ nacInfoMap of
                  Nothing -> return (ruleLG,ruleLGI)
                  Just (nacdg,(nM,eM),(nI,eI)) -> do
                    let nodeM = foldr (\n m -> if M.notMember n m then M.insert n n m else m) nM (nodeIds ruleLG)
                        edgeM = foldr (\n m -> if M.notMember n m then M.insert n n m else m) eM (edgeIds ruleLG)
                        ruleLG' = joinElementsFromMapping ruleLG (nodeM,edgeM)
                    case (G.null $ fst nacdg) of
                      True -> return (ruleLG', ruleLGI)
                      False -> return $ joinNAC (nacdg,(nM,eM),(nI,eI)) (ruleLG', ruleLGI) tg
                writeIORef st $ editorSetGI gi . editorSetGraph nG $ es
                writeIORef undoStack u
                writeIORef redoStack r
                writeIORef currentGraph index
              Nothing -> return ()

          (False, _) -> do
            -- update the current path
            writeIORef currentPath path
            -- update the current graph in the tree
            storeCurrentES
            -- load the selected graph from the tree
            writeIORef currentGraphType gType
            states <- readIORef graphStates
            let maybeState = M.lookup index states
            case maybeState of
              Just (es,u,r) -> do
                writeIORef st es
                writeIORef undoStack u
                writeIORef redoStack r
                writeIORef currentGraph index
              Nothing -> return ()

        -- auxiliar function to update nodes and edges elements according to the active typeGraph
        let updateElements = do
              pnt <- readIORef possibleNodeTypes
              pet <- readIORef possibleEdgeTypes
              es <- readIORef st
              let g = editorGetGraph es
                  (ngi, egi) = editorGetGI es
                  fn node = (nid, infoType (nodeInfo node), getNodeGI nid ngi)
                            where nid = fromEnum (nodeId node)
                  gn (i,t,gi) = case M.lookup t pnt of
                                  Nothing -> (i,gi)
                                  Just (gi',_) -> (i,nodeGiSetColor (fillColor gi') . nodeGiSetShape (shape gi') $ gi)
                  fe edge = (eid, infoType (edgeInfo edge), getEdgeGI eid egi)
                            where eid = fromEnum (edgeId edge)
                  ge (i,t,gi) = case M.lookup t pet of
                                  Nothing -> (i,gi)
                                  Just (gi',_) -> (i,edgeGiSetColor (color gi') . edgeGiSetStyle (style gi') $ gi)
                  newNodeGI = M.fromList . map gn . map fn $ nodes g
                  newEdgeGI = M.fromList . map ge . map fe $ edges g
              writeIORef st (editorSetGI (newNodeGI, newEdgeGI) es)
        case (gType) of
          0 -> Gtk.widgetSetSensitive orv False
          1 -> do
            Gtk.widgetSetSensitive orv False
            changeInspector typeInspBox typeNameBox
          2 -> do
            Gtk.widgetSetSensitive orv False
            changeInspector hostInspBox hostNameBox
            writeIORef currentShape NCircle
            writeIORef currentStyle ENormal
            writeIORef currentC (1,1,1)
            writeIORef currentLC (0,0,0)
            updateElements
          3 -> do
            Gtk.widgetSetSensitive orv True
            changeInspector ruleInspBox ruleNameBox
            writeIORef currentShape NCircle
            writeIORef currentStyle ENormal
            writeIORef currentC (1,1,1)
            writeIORef currentLC (0,0,0)
            updateElements
          4 -> do
            Gtk.widgetSetSensitive orv True
            changeInspector hostInspBox hostNameBox
            writeIORef currentShape NCircle
            writeIORef currentStyle ENormal
            writeIORef currentC (1,1,1)
            writeIORef currentLC (0,0,0)
            updateElements
        Gtk.widgetQueueDraw canvas

  -- pressed the 'new rule' button on the treeview area
  -- create a new Rule
  on createRBtn #clicked $ do
    states <- readIORef graphStates
    let newKey = if M.size states > 0 then maximum (M.keys states) + 1 else 0
    (valid,parent) <- Gtk.treeModelIterNthChild store Nothing 2
    if not valid
      then return ()
      else do
        n <- Gtk.treeModelIterNChildren store (Just parent)
        iter <- Gtk.treeStoreAppend store (Just parent)
        storeSetGraphStore store iter ("Rule" ++ (show n), 0, newKey, 3, True, True)
        modifyIORef graphStates (M.insert newKey (emptyES,[],[]))

  -- pressed the 'remove rule' button on the treeview area
  -- remove a Rule
  on removeRBtn #clicked $ do
    selection <- Gtk.treeViewGetSelection treeview
    (sel,model,iter) <- Gtk.treeSelectionGetSelected selection
    if not sel
      then return ()
      else do
        gtype <- Gtk.treeModelGetValue store iter 3 >>= fromGValue :: IO Int32
        case gtype of
          3 -> do
            index <- Gtk.treeModelGetValue store iter 2 >>= fromGValue
            Gtk.treeStoreRemove store iter
            modifyIORef graphStates $ M.delete index
          _ -> showError window "Selected Graph is not a rule."


  -- pressed the 'create NAC' vutton on the treeview area
  -- create NAC for the current rule
  on createNBtn #clicked $ do
    states <- readIORef graphStates
    selection <- Gtk.treeViewGetSelection treeview
    (sel, model, iterR) <- Gtk.treeSelectionGetSelected selection
    if not sel
      then return ()
      else do
        gtype <- Gtk.treeModelGetValue store iterR 3 >>= fromGValue :: IO Int32
        index <- Gtk.treeModelGetValue store iterR 2 >>= fromGValue :: IO Int32
        case gtype of
          3 -> do
            storeCurrentES
            states <- readIORef graphStates
            let state = fromMaybe (emptyES,[],[]) $ M.lookup index states
                (es,_,_) = state
                (lhs,_,_) = graphToRuleGraphs (editorGetGraph es)
                nodeMap = M.fromList $ map (\a -> (a,a)) $ nodeIds lhs
                edgeMap = M.fromList $ map (\a -> (a,a)) $ edgeIds lhs
                gi = editorGetGI es
                gi' = (M.filterWithKey (\k a -> (NodeId k) `elem` (nodeIds lhs)) (fst gi), M.filterWithKey (\k a -> (EdgeId k) `elem` (edgeIds lhs)) (snd gi))
            let newKey = if M.size states > 0 then maximum (M.keys states) + 1 else 0
            n <- Gtk.treeModelIterNChildren store (Just iterR)
            iterN <- Gtk.treeStoreAppend store (Just iterR)
            storeSetGraphStore store iterN ("NAC" ++ (show n), 0, newKey, 4, True, True)
            modifyIORef nacInfoMapIORef (M.insert newKey (DG.empty,(nodeMap,edgeMap),(M.empty,M.empty)))
            modifyIORef graphStates (M.insert newKey (editorSetGraph lhs . editorSetGI gi $ emptyES,[],[]))
          _ -> showError window "Selected Graph is not a rule, it's not possible to create NACs for it."

  -- pressed the 'remove NAC' button on the treeview area
  -- remove a NAC
  on removeNBtn #clicked $ do
    selection <- Gtk.treeViewGetSelection treeview
    (sel,model,iter) <- Gtk.treeSelectionGetSelected selection
    if not sel
      then return ()
      else do
        gtype <- Gtk.treeModelGetValue store iter 3 >>= fromGValue :: IO Int32
        case gtype of
          4 -> do
              index <- Gtk.treeModelGetValue store iter 2 >>= fromGValue
              Gtk.treeStoreRemove store iter
              modifyIORef graphStates $ M.delete index
          _ -> showError window "Selected Graph is not a NAC"



  -- edited a graph name
  on nameRenderer #edited $ \pathStr newName -> do
    path <- Gtk.treePathNewFromString pathStr
    (v,iter) <- Gtk.treeModelGetIter store path
    if v
      then do
        gval <- toGValue (Just newName)
        Gtk.treeStoreSet store iter [0] [gval]
        writeIORef changedProject True
        indicateProjChanged window True
      else return ()

  on activeRenderer #toggled $ \pathRepr -> do
    path <- Gtk.treePathNewFromString pathRepr
    (valid, iter) <- Gtk.treeModelGetIter store path
    if valid
      then do
        gType <- Gtk.treeModelGetValue store iter 3 >>= \gv -> (fromGValue gv :: IO Int32)
        active <- Gtk.treeModelGetValue store iter 4 >>= \gv -> (fromGValue gv :: IO Bool)
        notActive <- toGValue (not active)
        case gType of
          3 -> do Gtk.treeStoreSetValue store iter 4 notActive
                  #showAll window
          _ -> return ()
      else return ()

  -- event bindings for the main window ----------------------------------------
  -- when click in the close button, the application must close
  on window #deleteEvent $ return $ do
    continue <- confirmOperation
    if continue
      then do
        Gtk.mainQuit
        return False
      else return True

  -- run the preogram ----------------------------------------------------------
  Gtk.main

------------------------------------------------------------------------------
-- Auxiliar Functions --------------------------------------------------------
------------------------------------------------------------------------------

-- Tree generation/manipulation ------------------------------------------------
genForestIds :: Tree.Forest a -> Int32 -> Tree.Forest Int32
genForestIds [] i = []
genForestIds (t:ts) i = t' : (genForestIds ts i')
  where (t',i') = genTreeId t i

genTreeId :: Tree.Tree a -> Int32 -> (Tree.Tree Int32, Int32)
genTreeId (Tree.Node x []) i = (Tree.Node i [], i + 1)
genTreeId (Tree.Node x f) i = (Tree.Node i f', i')
  where
    f' = genForestIds f (i+1)
    i' = (maximum (fmap maximum f')) + 1

-- Gtk.treeStore manipulation
initStore :: Gtk.TreeStore -> Gtk.TreeView ->  IO ()
initStore store treeview = do
  fstIter <- Gtk.treeStoreAppend store Nothing
  storeSetGraphStore store fstIter ("TypeGraph", 0, 0, 1, False, True)
  sndIter <- Gtk.treeStoreAppend store Nothing
  storeSetGraphStore store sndIter ("InitialGraph", 0, 1, 2, False, True)
  rulesIter <- Gtk.treeStoreAppend store Nothing
  storeSetGraphStore store rulesIter ("Rules", 0, 0, 0, False, True)
  fstRuleIter <- Gtk.treeStoreAppend store (Just rulesIter)
  storeSetGraphStore store fstRuleIter ("Rule0", 0, 2, 3, True, True)
  path <- Gtk.treeModelGetPath store fstIter
  Gtk.treeViewSetCursor treeview path (Nothing :: Maybe Gtk.TreeViewColumn) False
  rulesPath <- Gtk.treeModelGetPath store rulesIter
  Gtk.treeViewExpandRow treeview rulesPath True
  return ()

storeSetGraphStore :: Gtk.TreeStore -> Gtk.TreeIter -> GraphStore -> IO ()
storeSetGraphStore store iter (n,c,i,t,a,v) = do
  gv0 <- toGValue (Just n)
  gv1 <- toGValue c
  gv2 <- toGValue i
  gv3 <- toGValue t
  gv4 <- toGValue a
  gv5 <- toGValue v
  #set store iter [0,1,2,3,4,5] [gv0,gv1,gv2,gv3,gv4,gv5]

getTreeStoreValues :: Gtk.TreeStore -> Gtk.TreeIter -> IO (Tree.Forest (Int32,(String,Int32,Bool)))
getTreeStoreValues store iter = do
  valT <- Gtk.treeModelGetValue store iter 3 >>= fromGValue :: IO Int32
  valN <- Gtk.treeModelGetValue store iter 0 >>= (\n -> fromGValue n :: IO (Maybe String)) >>= return . fromJust
  valI <- Gtk.treeModelGetValue store iter 2 >>= fromGValue :: IO Int32
  valA <- Gtk.treeModelGetValue store iter 4 >>= fromGValue :: IO Bool
  case valT of
    -- Topic
    0 -> do (valid, childIter) <- Gtk.treeModelIterChildren store (Just iter)
            subForest <- if valid
                          then getTreeStoreValues store childIter
                          else return []
            continue <- Gtk.treeModelIterNext store iter
            if continue
              then do
                newVals <- getTreeStoreValues store iter
                return $ (Tree.Node (valT, (valN, valI, valA)) subForest) : newVals
              else return $ (Tree.Node (valT, (valN, valI, valA)) subForest) : []
    -- Graphs
    _ -> do continue <- Gtk.treeModelIterNext store iter
            if continue
              then do
                newVals <- getTreeStoreValues store iter
                return $ (Tree.Node (valT, (valN, valI, valA)) []) : newVals
              else return $ (Tree.Node (valT, (valN, valI, valA)) []) : []

getStructsToSave :: Gtk.TreeStore -> IORef (M.Map Int32 (EditorState, [DiaGraph], [DiaGraph]))-> IO (Tree.Forest SaveInfo)
getStructsToSave store graphStates = do
  (valid, fstIter) <- Gtk.treeModelGetIterFirst store
  if not valid
    then return []
    else do
      treeNodeList <- getTreeStoreValues store fstIter
      states <- readIORef graphStates
      let structs = map
                    (fmap (\(t, (name, nid, active)) -> case t of
                                0 -> Topic name
                                1 -> let (es,_,_) = fromJust $ M.lookup nid states
                                     in TypeGraph name es
                                2 -> let (es,_,_) = fromJust $ M.lookup nid states
                                     in HostGraph name es
                                3 -> let (es,_,_) = fromJust $ M.lookup nid states
                                     in RuleGraph name es active
                    )) treeNodeList
      return structs

-- auxiliar function to load parent graph
getParentDiaGraph :: Gtk.TreeStore -> [Int32] -> IORef (M.Map Int32 (EditorState, [DiaGraph], [DiaGraph])) -> IO DiaGraph
getParentDiaGraph store pathIndices graphStates = do
  path <- Gtk.treePathNewFromIndices pathIndices
  (validIter, iter) <- Gtk.treeModelGetIter store path
  (valid, parent) <- if validIter
                        then Gtk.treeModelIterParent store iter
                        else return (False,iter)
  if valid
    then do
      index <- Gtk.treeModelGetValue store parent 2 >>= fromGValue :: IO Int32
      states <- readIORef graphStates
      state <- return $ M.lookup index states
      case state of
        Nothing -> return DG.empty
        Just (es,_,_) -> return (lhs, (ngi,egi))
                    where (lhs,_,_) = graphToRuleGraphs $ editorGetGraph es
                          ngi = M.filterWithKey (\k a -> (NodeId k) `elem` (nodeIds lhs)) $ fst (editorGetGI es)
                          egi = M.filterWithKey (\k a -> (EdgeId k) `elem` (edgeIds lhs)) $ snd (editorGetGI es)
    else return DG.empty

getRuleList :: Gtk.TreeStore ->  Gtk.TreeIter -> M.Map Int32 (EditorState, [DiaGraph], [DiaGraph]) -> IO [(Graph String String, String)]
getRuleList model iter gStates = do
  name <- Gtk.treeModelGetValue model iter 0 >>= fromGValue >>= return . fromJust :: IO String
  index <- Gtk.treeModelGetValue model iter 2 >>= fromGValue :: IO Int32
  res <- case M.lookup index gStates of
    Nothing -> return []
    Just (es, _, _) -> return $ [(editorGetGraph es, name)]
  continue <- Gtk.treeModelIterNext model iter
  if continue
    then do
      rest <- getRuleList model iter gStates
      return $ res ++ rest
    else return res

getRules :: Gtk.TreeStore -> IORef (M.Map Int32 (EditorState, [DiaGraph], [DiaGraph])) -> IO [(Graph String String,String)]
getRules model graphStates = do
  (valid, iter) <- Gtk.treeModelGetIterFromString model "2:0"
  if not valid
    then return []
    else do
      gStates <- readIORef graphStates
      getRuleList model iter gStates

-- update the active typegraph if the corresponding diagraph is valid, set it as empty if not
updateActiveTG :: IORef EditorState -> IORef (Graph String String) -> IORef (M.Map String (NodeGI, Int32)) -> IORef (M.Map String (EdgeGI, Int32)) -> IO ()
updateActiveTG st activeTypeGraph possibleNodeTypes possibleEdgeTypes = do
        es <- readIORef st
        -- check if all edges and nodes have different names
        let g = editorGetGraph es
            giM = editorGetGI es
            nds = nodes g
            edgs = edges g
            allDiff l = case l of
                          [] -> True
                          x:xs -> (notElem x xs) && (allDiff xs)
            diffNames = (allDiff (map (infoLabel . nodeInfo) nds)) &&
                        (allDiff (map (infoLabel . edgeInfo) edgs)) &&
                        notElem "" (concat [(map (infoLabel . edgeInfo) edgs), (map (infoLabel . nodeInfo) nds)])
        if diffNames
          then do -- load the variables with the info from the typeGraph
            writeIORef activeTypeGraph g
            writeIORef possibleNodeTypes $
                M.fromList $
                zipWith (\i (k,gi) -> (k, (gi, i)) ) [0..] $
                M.toList $
                foldr (\(Node nid info) m -> let ngi = getNodeGI (fromEnum nid) (fst giM)
                                                 in M.insert (infoLabel info) ngi m) M.empty nds
            writeIORef possibleEdgeTypes $
                M.fromList $
                zipWith (\i (k,gi) -> (k, (gi, i)) ) [0..] $
                M.toList $
                foldr (\(Edge eid _ _ info) m -> let egi = getEdgeGI (fromEnum eid) (snd giM)
                                                     in M.insert (infoLabel info) egi m) M.empty edgs
          else do
            writeIORef activeTypeGraph (G.empty)
            writeIORef possibleNodeTypes (M.empty)
            writeIORef possibleEdgeTypes (M.empty)

-- graph interaction
-- create a new node, auto-generating it's name and dimensions
createNode' :: IORef EditorState -> String -> Bool -> GIPos -> NodeShape -> GIColor -> GIColor -> P.Context ->  IO ()
createNode' st content autoNaming pos nshape color lcolor context = do
  es <- readIORef st
  let nid = head $ newNodes (editorGetGraph es)
      content' = if infoVisible content == "" && autoNaming then infoSetLabel content (show nid) else content
  dim <- getStringDims (infoVisible content') context Nothing
  writeIORef st $ createNode es pos dim content' nshape color lcolor

-- rename the selected itens
renameSelected:: IORef EditorState -> String -> P.Context -> IO()
renameSelected state content context = do
  es <- readIORef state
  -- auxiliar function rename
  let rename oldInfo = case ((infoType content) == "", (infoOperation content) == "", content) of
                        (True, True, ':':cs) -> infoSetType cs (infoType oldInfo)
                        (True, True, _) -> infoSetOperation (infoSetType content (infoType oldInfo)) (infoOperation oldInfo)
                        (True, False, _) -> infoSetType content (infoType oldInfo)
                        (False, True, ':':cs) -> infoSetOperation content ""
                        (False, True, _) -> infoSetOperation content (infoOperation oldInfo)
                        (False, False, _) -> content
  let graph = editorGetGraph es
      (nids,eids) = editorGetSelected es
      -- apply rename in the graph elements to get newGraph
      graph' = foldl (\g nid -> updateNodePayload nid g rename) graph nids
      newGraph  = foldl (\g eid -> updateEdgePayload eid g rename) graph' eids
  -- change the GraphicalInfo of the renamed elements
  let (ngiM,egiM) = editorGetGI es
  dims <- forM (filter (\n -> nodeId n `elem` nids) (nodes newGraph))
               (\n -> do
                     let info = nodeInfo n
                         op = infoOperation info
                         fontdesc = if op == "" then Nothing else Just "Sans Bold 10"
                     dim <- getStringDims (infoVisible info) context fontdesc
                     return (nodeId n, dim)
               )
  let newNgiM = M.mapWithKey (\k gi -> case lookup (NodeId k) dims of
                                        Just dim -> nodeGiSetDims dim gi
                                        Nothing -> gi)
                             ngiM
      newEs   = editorSetGI (newNgiM,egiM) . editorSetGraph newGraph $ es
  writeIORef state newEs

-- auxiliar function used by createNode' and renameSelected
-- given a text, compute the size of it's bounding box
-- uses the pango lib
getStringDims :: String -> P.Context -> Maybe T.Text -> IO (Double, Double)
getStringDims str context font = do
  desc <- case font of
    Just f -> P.fontDescriptionFromString f
    Nothing -> P.fontDescriptionFromString "Sans Regular 10"
  pL <- P.layoutNew context
  P.layoutSetFontDescription pL (Just desc)
  P.layoutSetText pL (T.pack str) (fromIntegral . length $ str)
  (_,rect) <- P.layoutGetExtents pL
  w <- get rect #width >>= (\n -> return . fromIntegral . quot n $ P.SCALE)
  h <- get rect #height >>= (\n -> return . fromIntegral . quot n $ P.SCALE)
  return (w +4, h + 4)


-- Undo / Redo -----------------------------------------------------------------
stackUndo :: IORef [DiaGraph] -> IORef [DiaGraph] -> EditorState -> IO ()
stackUndo undo redo es = do
  let g = editorGetGraph es
      gi = editorGetGI es
  modifyIORef undo (\u -> (g,gi):u )
  modifyIORef redo (\_ -> [])

applyUndo :: IORef [DiaGraph] -> IORef [DiaGraph] -> IORef EditorState -> IO ()
applyUndo undoStack redoStack st = do
  es <- readIORef st
  undo <- readIORef undoStack
  redo <- readIORef redoStack
  let apply [] r es = ([],r, es)
      apply ((g,gi):u) r es = (u, (eg,egi):r, editorSetGI gi . editorSetGraph g $ es)
                            where
                              eg = editorGetGraph es
                              egi = editorGetGI es
      (nu, nr, nes) = apply undo redo es
  writeIORef undoStack nu
  writeIORef redoStack nr
  writeIORef st nes

applyRedo :: IORef [DiaGraph] -> IORef [DiaGraph] -> IORef EditorState -> IO ()
applyRedo undoStack redoStack st = do
  undo <- readIORef undoStack
  redo <- readIORef redoStack
  es <- readIORef st
  let apply u [] es = (u, [], es)
      apply u ((g,gi):r) es = ((eg,egi):u, r, editorSetGI gi . editorSetGraph g $ es)
                            where
                              eg = editorGetGraph es
                              egi = editorGetGI es
      (nu, nr, nes) = apply undo redo es
  writeIORef undoStack nu
  writeIORef redoStack nr
  writeIORef st nes


-- Copy / Paste / Cut ----------------------------------------------------------
copySelected :: EditorState -> DiaGraph
copySelected  es = (cg,(ngiM',egiM'))
  where
    (nids,eids) = editorGetSelected es
    g = editorGetGraph es
    (ngiM, egiM) = editorGetGI es
    cnodes = foldr (\n ns -> if nodeId n `elem` nids
                              then (Node (nodeId n) (infoSetLocked (nodeInfo n) False)):ns
                              else ns) [] (nodes g)
    cedges = foldr (\e es -> if edgeId e `elem` eids
                              then (Edge (edgeId e) (sourceId e) (targetId e) (infoSetLocked (edgeInfo e) False):es)
                              else es) [] (edges g)
    -- cnodes = map (\n -> Node (nodeId n) (infoSetLocked (nodeInfo n) False)) $ filter (\n -> nodeId n `elem` nids) $ nodes g
    -- cedges = filter (\e -> edgeId e `elem` eids) $ edges g
    cg = fromNodesAndEdges cnodes cedges
    ngiM' = M.filterWithKey (\k _ -> NodeId k `elem` nids) ngiM
    egiM' = M.filterWithKey (\k _ -> EdgeId k `elem` eids) egiM

pasteClipBoard :: DiaGraph -> EditorState -> EditorState
pasteClipBoard (cGraph, (cNgiM, cEgiM)) es = editorSetGI (newngiM,newegiM) . editorSetGraph newGraph . editorSetSelected ([], [])$ es
  where
    graph = editorGetGraph es
    (ngiM, egiM) = editorGetGI es
    allPositions = concat [map position (M.elems cNgiM), map (getEdgePosition cGraph (cNgiM, cEgiM)) (edges cGraph)]
    minX = minimum $ map fst allPositions
    minY = minimum $ map snd allPositions
    upd (a,b) = (20+a-minX, 20+b-minY)
    cNgiM' = M.map (\gi -> nodeGiSetPosition (upd $ position gi) gi) cNgiM
    (newGraph, (newngiM,newegiM)) = diagrDisjointUnion (graph,(ngiM,egiM)) (cGraph,(cNgiM', cEgiM))


-- TreeStore Flags -------------------------------------------------------------
-- change window name to indicate if the project was modified
indicateProjChanged :: Gtk.Window -> Bool -> IO ()
indicateProjChanged window True = do
  ttitle <- get window #title
  let title = T.unpack . fromJust $ ttitle
  if title!!0 == '*'
    then return ()
    else set window [#title := T.pack('*':title)]

indicateProjChanged window False = do
  ttitle <- get window #title
  let i:title = T.unpack . fromJust $ ttitle
  if i == '*'
    then set window [#title := T.pack title]
    else return ()

-- write in the treestore that the current graph was modified
indicateGraphChanged :: Gtk.TreeStore -> Gtk.TreeIter -> Bool -> IO ()
indicateGraphChanged store iter True = do
  gtype <- Gtk.treeModelGetValue store iter 3 >>= fromGValue :: IO Int32
  if gtype == 0
    then return ()
    else do
      gvchanged <- toGValue (1::Int32)
      Gtk.treeStoreSetValue store iter 1 gvchanged
      (valid, parentIter) <- Gtk.treeModelIterParent store iter
      if valid
        then Gtk.treeStoreSetValue store parentIter 1 gvchanged
        else return ()

indicateGraphChanged store iter False = do
  gvchanged <- toGValue (0::Int32)
  Gtk.treeStoreSetValue store iter 1 gvchanged
  (valid, parentIter) <- Gtk.treeModelIterParent store iter
  if valid
    then Gtk.treeStoreSetValue store parentIter 1 gvchanged
    else return ()

-- change the flags that inform if the graphs and project were changed and indicate the changes
setChangeFlags :: Gtk.Window -> Gtk.TreeStore -> IORef Bool -> IORef [Bool] -> IORef [Int32] -> IORef Int32 -> Bool -> IO ()
setChangeFlags window store changedProject changedGraph currentPath currentGraph changed = do
  index <- readIORef currentGraph >>= return . fromIntegral
  xs <- readIORef changedGraph
  let xs' = take index xs ++ [changed] ++ drop (index+1) xs
      projChanged = or xs'
  writeIORef changedGraph xs'
  writeIORef changedProject $ projChanged
  indicateProjChanged window $ projChanged
  path <- readIORef currentPath >>= Gtk.treePathNewFromIndices
  (valid,iter) <- Gtk.treeModelGetIter store path
  if valid
    then indicateGraphChanged store iter changed
    else return ()

-- Analise a graph and change the flags that inform if a graph is valid/invalid
setValidFlag :: Gtk.TreeStore -> Gtk.TreeIter -> M.Map Int32 (EditorState, [DiaGraph], [DiaGraph]) -> Graph String String -> IO ()
setValidFlag store iter states tg = do
  index <- Gtk.treeModelGetValue store iter 2 >>= fromGValue :: IO Int32
  mst <- return $ M.lookup index states
  g <- case mst of
    Nothing -> return G.empty
    Just (es, u, r) -> return $ editorGetGraph es
  let valid = isGraphValid g tg
  gvValid <- toGValue valid
  Gtk.treeStoreSetValue store iter 5 gvValid

-- walk in the treeStore, applying setValidFalg for all the hostGraphs and RuleGraphs
-- should be called when occur an update to the typeGraph
setValidFlags :: Gtk.TreeStore -> Graph String String -> M.Map Int32 (EditorState, [DiaGraph], [DiaGraph]) -> IO ()
setValidFlags store tg states = do
  Gtk.treeModelForeach store $ \model path iter -> do
    t <- Gtk.treeModelGetValue store iter 3 >>= fromGValue :: IO Int32
    case t of
      0 -> return ()
      1 -> return ()
      2 -> setValidFlag store iter states tg
      3 -> setValidFlag store iter states tg
      4 -> setValidFlag store iter states tg
    return False

-- Change the valid flag for the graph that is being edited
-- Needed because the graphStates IORef is not updated while the user is editing the graph
setCurrentValidFlag :: Gtk.TreeStore -> IORef EditorState -> IORef (Graph String String) -> IORef [Int32] -> IO ()
setCurrentValidFlag store st typeGraph currentPath = do
      es <- readIORef st
      tg <- readIORef typeGraph
      let valid = isGraphValid (editorGetGraph es) tg
      gvValid <- toGValue valid
      cpath <- readIORef currentPath >>= Gtk.treePathNewFromIndices
      (validIter, iter) <- Gtk.treeModelGetIter store cpath
      if validIter
        then Gtk.treeStoreSetValue store iter 5 gvValid
        else return ()

-- change updatedState
updateSavedState :: IORef (M.Map Int32 DiaGraph) -> IORef (M.Map Int32 (EditorState, [DiaGraph], [DiaGraph])) -> IO ()
updateSavedState sst graphStates = do
  states <- readIORef graphStates
  writeIORef sst $ (M.map (\(es,_,_) -> (editorGetGraph es, editorGetGI es) ) states)




joinNAC :: (DiaGraph, MergeMapping, InjectionMapping) -> DiaGraph -> Graph Info Info -> DiaGraph
joinNAC (nacdg, (nM,eM), (nI,eI)) lhsdg@(ruleLG,ruleLGI) tg = (nG, nGI)
 where
   -- change ids of elements of nacs so that those elements don't have conflicts
   -- with elements from lhs
   (nacG,nacGI) = remapElementsWithConflict lhsdg nacdg (nI,eI)
   -- apply a pushout in  elements of nac
   tg' = makeTypeGraph tg
   lm = makeTypedGraph ruleLG tg'
   nm = makeTypedGraph nacG tg'
   (nacTgmLhs,nacTgmNac) = getNacPushout nm lm (nI, eI)
   -- inverse relations from graphs resulting of pushout to change their elements ids to the correct ones
   nIRLHS = R.inverseRelation $ Morph.nodeRelation $ TGM.mapping nacTgmLhs
   eIRLHS = R.inverseRelation $ Morph.edgeRelation $ TGM.mapping nacTgmLhs
   nIRNAC = R.inverseRelation $ Morph.nodeRelation $ TGM.mapping nacTgmNac
   eIRNAC = R.inverseRelation $ Morph.edgeRelation $ TGM.mapping nacTgmNac
   nGJust = TG.toUntypedGraph $ TGM.codomainGraph nacTgmLhs
   swapNodeId' n = case (R.apply nIRLHS n ++ R.apply nIRNAC n) of
                     []       -> n
                     nid:nids -> nid
   swapNodeId n = Node (swapNodeId' (nodeId n)) (nodeInfo n)
   swapEdgeId e = case (R.apply eIRLHS (edgeId e) ++ R.apply eIRNAC (edgeId e)) of
                     []       -> e
                     eid:eids -> Edge eid (swapNodeId' $ sourceId e) (swapNodeId' $ targetId e) (edgeInfo e)
   nGnodes = map swapNodeId . map nodeFromJust $ nodes nGJust
   nGedges = map swapEdgeId . map edgeFromJust $ edges nGJust
   nG = fromNodesAndEdges nGnodes nGedges
   nGI = (M.union (fst nacGI) (fst ruleLGI), M.union (snd nacGI) (snd ruleLGI))
