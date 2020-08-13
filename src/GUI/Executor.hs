{-# LANGUAGE OverloadedStrings, OverloadedLabels #-}
module GUI.Executor (
  buildExecutor
, ExecGraphEntry
, updateTreeStore
, removeFromTreeStore
, removeTrashFromTreeStore
) where

import qualified GI.Gtk as Gtk
import qualified GI.Gdk as Gdk
import Graphics.Rendering.Cairo (Render)

import           Control.Monad.IO.Class
import           Data.IORef
import           Data.Maybe
import qualified Data.Map as M
import           Data.GI.Base
import           Data.GI.Base.ManagedPtr (unsafeCastTo)
import           Data.Int

import qualified Data.Graphs as G

import           GUI.Data.DiaGraph hiding (empty)
import qualified GUI.Data.DiaGraph as DG
import           GUI.Data.EditorState
import           GUI.Data.Info
import           GUI.Data.Nac
import           GUI.Render.Render
import           GUI.Render.GraphDraw
import           GUI.Helper.GrammarMaker

-- this should not be used, but let if be for now
import qualified GUI.Editor as Editor (basicCanvasButtonPressedCallback, basicCanvasMotionCallBack, basicCanvasButtonReleasedCallback)

buildExecutor :: Gtk.TreeStore 
              -> IORef (M.Map Int32 EditorState) 
              -> IORef (G.Graph Info Info) 
              -> IORef (M.Map Int32 NacInfo)
              -> IO (Gtk.Paned, IORef EditorState, IORef Bool)
buildExecutor store statesMap typeGraph nacInfoMap = do
    builder <- new Gtk.Builder []
    Gtk.builderAddFromFile builder "./Resources/executor.glade"

    executorPane <- Gtk.builderGetObject builder "executorPane" >>= unsafeCastTo Gtk.Paned . fromJust

    execPane  <- Gtk.builderGetObject builder "execPane" >>= unsafeCastTo Gtk.Paned . fromJust 
    hideRVBtn <- Gtk.builderGetObject builder "hideRVBtn" >>= unsafeCastTo Gtk.Button . fromJust

    mainCanvas <- Gtk.builderGetObject builder "mainCanvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
    nacCanvas  <- Gtk.builderGetObject builder "nacCanvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
    lCanvas    <- Gtk.builderGetObject builder "lCanvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
    rCanvas    <- Gtk.builderGetObject builder "rCanvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
    ruleCanvas    <- Gtk.builderGetObject builder "ruleCanvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
    Gtk.widgetSetEvents mainCanvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]
    Gtk.widgetSetEvents nacCanvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]
    Gtk.widgetSetEvents lCanvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]
    Gtk.widgetSetEvents rCanvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]
    Gtk.widgetSetEvents ruleCanvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]

    nacCBox <- Gtk.builderGetObject builder "nacCBox" >>= unsafeCastTo Gtk.ComboBoxText . fromJust

    stopBtn <- Gtk.builderGetObject builder "stopBtn" >>= unsafeCastTo Gtk.Button . fromJust

    treeView <- Gtk.builderGetObject builder "treeView" >>= unsafeCastTo Gtk.TreeView . fromJust
    Gtk.treeViewSetModel treeView (Just store)

    -- IORefs -------------------------------------------------------------------------------------------------------------------
    hostState   <- newIORef emptyES -- state refering to the init graph with rules applied
    ruleState   <- newIORef emptyES -- state refering to the graph of the selected rule
    lState      <- newIORef emptyES -- state refering to the graph of the left side of selected rule
    rState      <- newIORef emptyES -- state refering to the graph of the right side of selected rule
    kGraph      <- newIORef G.empty -- k graph needed for displaying ids in the left and right sides of rules
    nacState    <- newIORef emptyES -- state refering to the graph of nac
    
    currentNACIndex    <- newIORef (-1 :: Int32) -- index of current selected NAC
    currentRuleIndex   <- newIORef (-1 :: Int32) -- index of currentRule


    execStarted  <- newIORef False   -- if execution has already started
        

    -- callbacks ----------------------------------------------------------------------------------------------------------------
    -- hide rule viewer panel when colse button is pressed
    on hideRVBtn #pressed $ do
        closePos <- get execPane #maxPosition
        Gtk.panedSetPosition execPane closePos

    -- canvas
    setCanvasCallBacks mainCanvas hostState typeGraph (Just drawHostGraph)
    setCanvasCallBacks ruleCanvas ruleState typeGraph (Just drawRuleGraph)
    setCanvasCallBacks lCanvas lState kGraph (Just drawRuleSideGraph)
    setCanvasCallBacks rCanvas rState kGraph (Just drawRuleSideGraph)
    setCanvasCallBacks rCanvas rState kGraph (Just drawRuleSideGraph)
    (_,nacSqrSel)<- setCanvasCallBacks nacCanvas nacState typeGraph Nothing
    on nacCanvas #draw $ \context -> do
        es <- readIORef nacState
        tg <- readIORef typeGraph
        sq <- readIORef nacSqrSel
        index <- readIORef currentNACIndex
        (_,mm) <- readIORef nacInfoMap >>= return . fromMaybe (DG.empty, (M.empty,M.empty)) . M.lookup index
        renderWithContext context $ drawNACGraph es sq tg mm
        return False


    -- when select a rule, change their states
    on treeView #cursorChanged $ do
        selection <- Gtk.treeViewGetSelection treeView
        (sel,model,iter) <- Gtk.treeSelectionGetSelected selection
        if sel
            then do
                index <- Gtk.treeModelGetValue model iter 1 >>= fromGValue :: IO Int32
                gType <- Gtk.treeModelGetValue model iter 2 >>= fromGValue :: IO Int32
                statesM <- readIORef statesMap
                (maybeRuleIndex, maybeNACIndex) <- case gType of
                        3 -> do
                            (valid,childIter) <- Gtk.treeModelIterChildren model (Just iter)
                            nacIndex <- if valid
                                            then do
                                                childIndex <- Gtk.treeModelGetValue model childIter 1 >>= fromGValue :: IO Int32
                                                return $ Just childIndex
                                            else return Nothing
                            return (Just index,nacIndex)
                        4 -> do
                            (valid,parentIter) <- Gtk.treeModelIterParent model iter 
                            ruleIndex <- if valid
                                            then do
                                                parentIndex <- Gtk.treeModelGetValue model parentIter 1 >>= fromGValue :: IO Int32
                                                return $ Just parentIndex
                                            else return Nothing
                            return (ruleIndex, Just index)
                        _ -> return (Nothing,Nothing)
                case maybeRuleIndex of
                    Nothing -> do 
                        -- TODO: show error
                        writeIORef ruleState $ emptyES
                        writeIORef lState $ emptyES
                        writeIORef rState $ emptyES
                    Just rIndex -> do
                        currRIndex <- readIORef currentRuleIndex
                        if (currRIndex == rIndex)
                            then return ()
                            else do
                                let es = fromMaybe emptyES $ M.lookup rIndex statesM
                                    g = editorGetGraph es
                                    (l,k,r) = graphToRuleGraphs g
                                    (ngiM,egiM) = editorGetGI es
                                    lngiM = M.filterWithKey (\k a -> (G.NodeId k) `elem` (G.nodeIds l)) ngiM
                                    legiM = M.filterWithKey (\k a -> (G.EdgeId k) `elem` (G.edgeIds l)) egiM
                                    rngiM = M.filterWithKey (\k a -> (G.NodeId k) `elem` (G.nodeIds r)) ngiM
                                    regiM = M.filterWithKey (\k a -> (G.EdgeId k) `elem` (G.edgeIds r)) egiM
                                    (_,lgi) = adjustDiagrPosition (l,(lngiM,legiM))
                                    (_,rgi) = adjustDiagrPosition (r,(rngiM,regiM))
                                    (_,gi') = adjustDiagrPosition (g,(ngiM,egiM))
                                    les = editorSetGraph l . editorSetGI lgi $ es
                                    res = editorSetGraph r . editorSetGI rgi $ es
                                    es' = editorSetGI gi' es
                                writeIORef ruleState es'
                                writeIORef lState les
                                writeIORef rState res
                                writeIORef kGraph k
                        case maybeNACIndex of
                            Nothing -> writeIORef nacState $ emptyES
                            Just nIndex -> do
                                let es = fromMaybe emptyES $ M.lookup nIndex statesM
                                    g  = editorGetGraph es
                                    gi = editorGetGI es
                                    (_,gi') = adjustDiagrPosition (g,gi)
                                    es' = editorSetGI gi' es
                                writeIORef nacState es'
                                writeIORef currentNACIndex nIndex
                Gtk.widgetQueueDraw lCanvas
                Gtk.widgetQueueDraw rCanvas
                Gtk.widgetQueueDraw ruleCanvas
                Gtk.widgetQueueDraw nacCanvas


            else return ()


    -- execution controls
    on stopBtn #pressed $ do
        statesM <- readIORef statesMap
        let initState = fromMaybe emptyES $ M.lookup 1 statesM
        writeIORef hostState initState
        writeIORef execStarted False
    

    --
    
    return (executorPane, hostState, execStarted)

type SquareSelection = Maybe (Double,Double,Double,Double)
setCanvasCallBacks :: Gtk.DrawingArea 
                   -> IORef EditorState 
                   -> IORef (G.Graph Info Info )
                   -> Maybe (EditorState -> SquareSelection -> G.Graph Info Info -> Render ()) 
                   -> IO (IORef (Double,Double), IORef SquareSelection)
setCanvasCallBacks canvas state refGraph drawMethod = do
    oldPoint        <- newIORef (0.0,0.0) -- last point where a mouse button was pressed
    squareSelection <- newIORef Nothing   -- selection box : Maybe (x1,y1,x2,y2)

    case drawMethod of
        Just draw -> do 
            on canvas #draw $ \context -> do
                es <- readIORef state
                rg <- readIORef refGraph
                sq <- readIORef squareSelection
                renderWithContext context $ draw es sq rg
                return False
            return ()
        Nothing -> return ()
    on canvas #buttonPressEvent $ Editor.basicCanvasButtonPressedCallback state oldPoint squareSelection canvas
    on canvas #motionNotifyEvent $ Editor.basicCanvasMotionCallBack state oldPoint squareSelection canvas
    on canvas #buttonReleaseEvent $ Editor.basicCanvasButtonReleasedCallback state squareSelection canvas 
    return (oldPoint,squareSelection) 

    



{-| ExecGraphEntry
    A tuple representing what is showed in each node of the tree in the treeview
    It contains the informations:
    * name,
    * id,
    * type (3 - rule, 4 - NAC),
    * parent id (used if type is NAC).
    * active
-}
type ExecGraphEntry = (String, Int32, Int32, Int32)

-- | set the ExecGraphStore in a position given by an iter in the TreeStore
storeSetGraphEntry :: Gtk.TreeStore -> Gtk.TreeIter -> ExecGraphEntry -> IO ()
storeSetGraphEntry store iter (n,i,t,p) = do
    gvn <- toGValue (Just n)
    gvi <- toGValue i
    gvt <- toGValue t
    gvp <- toGValue p
    #set store iter [0,1,2,3] [gvn,gvi,gvt,gvp]

-- search the treeStore for an entry. If the entry is found then update it, else create the entry.
updateTreeStore :: Gtk.TreeStore -> ExecGraphEntry -> IO ()
updateTreeStore store entry = do
    (valid,iter) <- Gtk.treeModelGetIterFirst store
    if valid
        then updateTreeStore' store iter entry
        else do
            iter <- Gtk.treeStoreAppend store Nothing
            storeSetGraphEntry store iter entry

updateTreeStore' :: Gtk.TreeStore -> Gtk.TreeIter -> ExecGraphEntry -> IO ()
updateTreeStore' store iter entry@(n,i,t,p) = do
    cid <- Gtk.treeModelGetValue store iter 1 >>= fromGValue :: IO Int32
    ct  <- Gtk.treeModelGetValue store iter 2 >>= fromGValue :: IO Int32
    if cid == i
        then storeSetGraphEntry store iter entry
        else do
            let updateInList parentIter = do
                    valid <- Gtk.treeModelIterNext store iter
                    if valid
                        then updateTreeStore' store iter entry
                        else do
                            newIter <- Gtk.treeStoreAppend store parentIter
                            storeSetGraphEntry store newIter entry
            case t of
                3 -> updateInList Nothing
                4 -> do
                    case (ct == 3,cid == p) of
                        (True,True) -> do
                            (valid,childIter) <- Gtk.treeModelIterChildren store (Just iter) 
                            if valid
                                then updateTreeStore' store childIter entry
                                else do
                                    childIter <- Gtk.treeStoreAppend store (Just iter)
                                    storeSetGraphEntry store childIter entry
                        (True,False) -> do
                            valid <- Gtk.treeModelIterNext store iter
                            if valid
                                then updateTreeStore' store iter entry
                                else return ()
                        _ -> do 
                            (valid,parentIter) <- Gtk.treeModelIterParent store iter
                            if valid
                                then updateInList (Just parentIter)
                                else return ()


removeFromTreeStore :: Gtk.TreeStore -> Int32 -> IO ()
removeFromTreeStore store index = do
    (valid, iter) <- Gtk.treeModelGetIterFirst store
    if valid
        then removeFromTreeStore' store iter index
        else return ()

removeFromTreeStore' :: Gtk.TreeStore -> Gtk.TreeIter -> Int32 -> IO ()
removeFromTreeStore' store iter index = do
    cindex <- Gtk.treeModelGetValue store iter 1 >>= fromGValue :: IO Int32
    if cindex == index
        then do 
            Gtk.treeStoreRemove store iter
            return ()
        else do 
            continue <- Gtk.treeModelIterNext store iter
            if continue 
                then removeFromTreeStore' store iter index
                else return ()



-- remove entries that contains invalid keys for the Map that it refers to
removeTrashFromTreeStore :: Gtk.TreeStore -> M.Map Int32 EditorState -> IO ()
removeTrashFromTreeStore store statesMap = do
    (valid, iter) <- Gtk.treeModelGetIterFirst store
    if valid
        then removeTrashFromTreeStore' store iter statesMap
        else return ()

removeTrashFromTreeStore' :: Gtk.TreeStore -> Gtk.TreeIter -> M.Map Int32 EditorState -> IO ()
removeTrashFromTreeStore' store iter statesMap = do
    index <- Gtk.treeModelGetValue store iter 1 >>= fromGValue :: IO Int32
    state <- return $ M.lookup index statesMap
    continue <- case state of
        Just st -> do 
            (hasChildren,childIter) <- Gtk.treeModelIterChildren store (Just iter)
            if hasChildren
                then removeTrashFromTreeStore' store childIter statesMap 
                else return ()
            Gtk.treeModelIterNext store iter                    
        Nothing -> Gtk.treeStoreRemove store iter
    if continue
        then removeTrashFromTreeStore' store iter statesMap
        else return ()
    
    


    
    

    