{-# LANGUAGE OverloadedStrings, OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables        #-}
module GUI.Analysis.ModelChecker (
  buildStateSpaceBox
) where

-- GTK modules
import qualified GI.Gtk as Gtk
import qualified GI.Gdk as Gdk
import qualified GI.Pango as P
import           Data.GI.Base
import           Graphics.Rendering.Cairo (Render)

-- modules needed for threads
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Exception.Base
import qualified GI.GLib as GLib

-- Haskell structures
import           Control.Monad
import           Data.IORef
import           Data.Int
import           Data.Maybe
import qualified Data.IntMap as IntMap
import qualified Data.Text   as T
import qualified Data.Map    as M
import qualified Data.Set    as Set
import qualified Data.List   as List
import           Data.Char
import qualified Data.Time.Clock   as Time


-- verigraph structures
import qualified  Abstract.Category                 as Cat
import qualified  Abstract.Rewriting.DPO            as DPO
import qualified  Abstract.Rewriting.DPO.StateSpace as SS
import qualified  Data.Graphs                       as G
import qualified  Data.TypedGraph.Morphism          as TGM
import qualified  Data.TypedGraph                   as TG
import            Rewriting.DPO.TypedGraph
import qualified  Logic.Ctl                         as Logic
import qualified  Logic.Model                       as Logic

-- GUI modules
import            GUI.Data.Info hiding (empty)
import qualified  GUI.Data.Info as Info
import            GUI.Data.Nac
import            GUI.Data.DiaGraph
import            GUI.Data.GraphState
import            GUI.Data.GraphicalInfo
import            GUI.Helper.BasicCanvasCallbacks
import            GUI.Helper.GraphicalInfo
import            GUI.Helper.GrammarMaker
import            GUI.Helper.FilePath
import            GUI.Dialogs
import            GUI.Render.Render
import            GUI.Render.GraphDraw

import qualified  GUI.Editor as Edit

-- User Interface -----------------------------------------------------------------------------------------
buildStateSpaceBox :: Gtk.Window
                   -> Gtk.TreeStore
                   -> Gtk.MenuItem
                   -> IORef (Maybe Gtk.DrawingArea)
                   -> IORef (Maybe (IORef GraphState))
                   -> IORef (M.Map Int32 GraphState)
                   -> IORef (M.Map Int32 (DiaGraph, MergeMapping))
                   -> IO (Gtk.Box)
buildStateSpaceBox window store genStateSpaceItem focusedCanvas focusedStateIORef graphStatesIORef nacsInfoIORef = do
  -- build -- box
  builder <- new Gtk.Builder []
  resourcesFolder <- getResourcesFolder
  Gtk.builderAddFromFile builder $ T.pack (resourcesFolder ++ "stateSpace.glade")

  mainBox <- Gtk.builderGetObject builder "main_box" >>= unsafeCastTo Gtk.Box . fromJust
  generateBtn <- Gtk.builderGetObject builder "generate_button" >>= unsafeCastTo Gtk.Button . fromJust
  stopBtn <- Gtk.builderGetObject builder "stop_button" >>= unsafeCastTo Gtk.Button . fromJust
  depthSpinBtn <- Gtk.builderGetObject builder "depth_spin_button" >>= unsafeCastTo Gtk.SpinButton . fromJust

  formulaEntry <- Gtk.builderGetObject builder "formula_entry" >>= unsafeCastTo Gtk.Entry . fromJust
  formulaCheckBtn <- Gtk.builderGetObject builder "check_formula_btn" >>= unsafeCastTo Gtk.Button . fromJust

  canvas <- Gtk.builderGetObject builder "canvas" >>= unsafeCastTo Gtk.DrawingArea . fromJust
  Gtk.widgetSetEvents canvas [toEnum $ fromEnum Gdk.EventMaskAllEventsMask - fromEnum Gdk.EventMaskSmoothScrollMask]

  statusSpinner <- Gtk.builderGetObject builder "status_spinner" >>= unsafeCastTo Gtk.Spinner . fromJust
  statusLabel <- Gtk.builderGetObject builder "status_label" >>= unsafeCastTo Gtk.Label . fromJust
  Gtk.spinnerStop statusSpinner
  Gtk.labelSetText statusLabel ""

  -- IORefs
  ssGraphState <- newIORef emptyState
  modelIORef <- newIORef Nothing
  execThread <- newIORef Nothing
  goodStatesIORef <- newIORef Nothing

  -- bindings ------------------------------------------------------------------------
  -- controls
  on genStateSpaceItem #activate $ do
    eGG <- Edit.prepToExport store graphStatesIORef nacsInfoIORef
    case eGG of
      Left msg -> showError window (T.pack msg)
      Right grammar -> do
        timeMVar <- newEmptyMVar
        ssIORef <- newIORef Nothing
        initialIORef <- newIORef 0
        constructThreadIORef <- newIORef Nothing
        constructEndedMVar <- newEmptyMVar
        statesNum <- Gtk.spinButtonGetValueAsInt depthSpinBtn >>= return . fromIntegral
        context <- Gtk.widgetGetPangoContext canvas
        execT <- forkFinally
                    (generateSSThread statusSpinner statusLabel canvas context timeMVar grammar statesNum ssIORef initialIORef ssGraphState modelIORef constructThreadIORef constructEndedMVar)
                    (generateSSThreadEnd statusSpinner statusLabel canvas context execThread timeMVar constructThreadIORef constructEndedMVar)
        writeIORef execThread (Just execT)

  on generateBtn #pressed $ Gtk.menuItemActivate genStateSpaceItem

  on stopBtn #pressed $ do
    execT <- readIORef execThread
    case execT of
      Nothing -> return ()
      Just t -> do
        killThread t
        writeIORef execThread Nothing

  -- chekc formula
  let checkFormula = do
        text <- Gtk.entryGetText formulaEntry
        exprStr <- return $ T.unpack text
        case Logic.parseExpr "" exprStr of
          Left err -> do
            showError window $ T.pack ("Invalid CTL formula:\n" ++ (show err))
          Right expr -> do
            maybeModel <- readIORef modelIORef
            case maybeModel of
              Nothing -> showError window $ "Must Generate State Space before checking a formula"
              Just model -> do
                modelCheck model expr goodStatesIORef
                Gtk.labelSetText statusLabel text

  on formulaCheckBtn #pressed $ checkFormula

  on formulaEntry #keyPressEvent $ \eventKey -> do
    k <- get eventKey #keyval >>= return . chr . fromIntegral
    --if it's Return or Enter (Numpad), then check formula
    case k of
      '\65293' -> checkFormula
      '\65421' -> checkFormula
      '\65288' -> do
          t <- Gtk.entryGetTextLength formulaEntry >>= return . fromIntegral
          if t == 0 then do
            writeIORef goodStatesIORef Nothing
            Gtk.labelSetText statusLabel ""
          else return ()
      _ -> return ()
    return False

  -- canvas - to draw the state space graph
  oldPoint        <- newIORef (0.0,0.0) -- last point where a mouse button was pressed
  squareSelection <- newIORef Nothing   -- selection box : Maybe (x1,y1,x2,y2)
  on canvas #draw $ \context -> do
    ss <- readIORef ssGraphState
    sq <- readIORef squareSelection
    gsts <- readIORef goodStatesIORef
    renderWithContext context   $ drawStateSpace ss sq gsts
    return False
  on canvas #buttonPressEvent   $ basicCanvasButtonPressedCallback ssGraphState oldPoint squareSelection canvas
  on canvas #motionNotifyEvent  $ basicCanvasMotionCallBack ssGraphState oldPoint squareSelection canvas
  on canvas #buttonReleaseEvent $ basicCanvasButtonReleasedCallback ssGraphState squareSelection canvas
  on canvas #scrollEvent        $ basicCanvasScrollCallback ssGraphState canvas
  on canvas #focusInEvent       $ \event -> do
      writeIORef focusedCanvas     $ Just canvas
      writeIORef focusedStateIORef $ Just ssGraphState
      return False

  return mainBox





type NamedPredicate a b = (String, TypedGraphRule a b)
type NamedProduction a b = (String, TypedGraphRule a b)
type Space a b = SS.StateSpace (TGM.TypedGraphMorphism a b)



generateSSThread :: Gtk.Spinner -> Gtk.Label -> Gtk.DrawingArea -> P.Context
                 -> MVar Time.UTCTime
                 -> DPO.Grammar (TGM.TypedGraphMorphism Info Info) -> Int
                 -> IORef (Maybe (Space Info Info)) -> IORef Int
                 -> IORef GraphState -> IORef (Maybe (Logic.KripkeStructure String))
                 -> IORef (Maybe ThreadId) -> MVar Bool
                 -> IO ()
generateSSThread statusSpinner statusLabel canvas context timeMVar grammar statesNum ssIORef initialIORef ssGraphState modelIORef constructThreadIORef constructEndedMVar = do
  -- get current time to compare and indicate the duration of the generation
  startTime <- Time.getCurrentTime
  putMVar timeMVar startTime

  -- indicate that the generation started
  Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $ do
      Gtk.spinnerStart statusSpinner
      Gtk.labelSetText statusLabel "generating state space"
      return False

  --
  let initialGraph = DPO.start grammar
      mconf = (DPO.MorphismsConfig Cat.monic) :: DPO.MorphismsConfig (TGM.TypedGraphMorphism Info Info)

  -- start thread to indicate the current status of the generation
  ssMVar <- newEmptyMVar
  indicateThread <- forkIO $ constructStateSpace statusLabel ssMVar initialGraph canvas context ssGraphState modelIORef constructEndedMVar
  writeIORef constructThreadIORef (Just indicateThread)

  -- generate state
  exploreStateSpace mconf statesNum grammar initialGraph ssMVar
  return ()


-- indicate how many states were created
constructStateSpace :: Gtk.Label -> MVar (Space Info Info) -> TG.TypedGraph Info Info
               -> Gtk.DrawingArea -> P.Context
               -> IORef GraphState -> IORef (Maybe (Logic.KripkeStructure String))
               -> MVar Bool
               -> IO ()
constructStateSpace statusLabel ssMVar initialGraph canvas context ssGraphState modelIORef endedMVar = do
  -- wait till there is something
  stateSpace <- takeMVar ssMVar
  _ <- tryTakeMVar endedMVar

  let getInitialId = do
          (idx,_) <- SS.putState initialGraph
          return idx

  let (idx,_) = SS.runStateSpaceBuilder getInitialId stateSpace

  -- indicate the number of states in the current space
  let s = IntMap.size $ SS.states stateSpace
  Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $ do
    Gtk.labelSetText statusLabel (T.pack ("generating state space ( " ++ (show s) ++ " states)"))
    return False

  -- build the model to make logical verifications and
  let model = SS.toKripkeStructure stateSpace
  writeIORef modelIORef (Just model)

  -- generate the graphState to show the space state
  let st = generateGraphState [idx] stateSpace
      (ngi,egi) = stateGetGI st
      g = stateGetGraph st
  ngi' <- updateNodesGiDims ngi g context
  st' <- return $ stateSetGI (ngi',egi) st

  -- update canvas
  Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $ do
    writeIORef ssGraphState st'
    Gtk.widgetQueueDraw canvas
    return False

  putMVar endedMVar True
  constructStateSpace statusLabel ssMVar initialGraph canvas context ssGraphState modelIORef endedMVar








generateSSThreadEnd :: Gtk.Spinner -> Gtk.Label -> Gtk.DrawingArea -> P.Context
                    -> IORef (Maybe ThreadId)
                    -> MVar Time.UTCTime
                    -> IORef (Maybe ThreadId)
                    -> MVar Bool
                    -> Either SomeException () -> IO ()
generateSSThreadEnd statusSpinner statusLabel canvas context execThread timeMVar constructThreadIORef constructEndedMVar e = do

  _ <- takeMVar constructEndedMVar

  -- stop the thread that generates the graphState and model for the state space
  constructThread <- readIORef constructThreadIORef
  case constructThread of
    Nothing -> return ()
    Just t -> killThread t


  -- get current time to compare and indicate the duration of the generation
  endTime <- Time.getCurrentTime
  emptyTime <- isEmptyMVar timeMVar
  if emptyTime then
    return ()
  else do
    startTime <- takeMVar timeMVar
    let diff = Time.diffUTCTime endTime startTime
    print diff

  -- indicate that the generation ended
  Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $ do
    Gtk.spinnerStop statusSpinner
    Gtk.labelSetText statusLabel ""
    return False

  writeIORef execThread Nothing



generateGraphState :: [Int] -> Space Info Info -> GraphState
generateGraphState initialStates stateSpace = st'
  where
    addLevel levels (a,b) = case M.lookup a levels of
                              Nothing -> M.insert b 1 $ M.insert a 0 levels
                              Just l -> M.alter
                                        (\mx -> case mx of
                                                  Nothing -> Just (l+1)
                                                  Just x -> Just (min x (l+1)))
                                        b levels
    nidsWithLevels = foldl addLevel (M.singleton 0 0) $ M.keys (SS.transitions stateSpace) :: M.Map Int Int
    organizeLevels a l levels = case M.lookup l levels of
                              Nothing -> M.insert l [a] levels
                              Just ls -> M.insert l (ls++[a]) levels
    levels = M.foldrWithKey organizeLevels (M.empty) nidsWithLevels :: M.Map Int [Int]
    getStatePredicates nid = fromMaybe [] $ snd <$> (IntMap.lookup nid (SS.states stateSpace))
    nodeWithPos nid posX posY =
      let
        predicates = getStatePredicates nid
        label = case predicates of
                  [] -> ("state " ++ show nid)
                  ps -> init . unlines $ ("state " ++ show nid ++ "\n"):predicates
      in
        (G.Node (G.NodeId nid) (infoSetLabel Info.empty label), (fromIntegral posX, fromIntegral posY))
    addNodeInLevel l nids nds = foldr (\(nid,posX) ls -> (nodeWithPos nid posX (l*100)):ls ) nds (zip nids [0,100..])
    nds = M.foldrWithKey addNodeInLevel [] levels
    ndsGIs = M.fromList $ map (\(n,pos) -> (fromEnum $ G.nodeId n, newNodeGI {position = pos, shape = NRect})) nds
    g = G.fromNodesAndEdges (map fst nds) []
    st = stateSetGI (ndsGIs,M.empty) $ stateSetGraph g $ emptyState
    st' = M.foldrWithKey (\(a,b) names st -> createEdge st Nothing (G.NodeId a) (G.NodeId b) (infoSetLabel Info.empty (init $ unlines names)) False ENormal (0,0,0)) st (SS.transitions stateSpace)


-- definitions taken from Verigraph CLI/ModelChecker.hs -------------------------------------------------------------
modelCheck :: Logic.KripkeStructure String -> Logic.Expr -> IORef (Maybe [G.NodeId]) -> IO ()
modelCheck model expr goodStatesIORef =
  let
    allGoodStates = Logic.satisfyExpr' model expr
  in do
    writeIORef goodStatesIORef $ Just (map G.NodeId allGoodStates)

-- | Separates the rules that change nothing (which are considered predicates)
-- from those that have some effect (which are considered productions).
splitPredicates :: [(String, TypedGraphRule a b)] -> ([NamedProduction a b], [NamedPredicate a b])
splitPredicates [] =
  ([], [])

splitPredicates ((name, rule) : rest) =
  let
    (productions, predicates) =
      splitPredicates rest
  in
    if Cat.isIsomorphism (leftMorphism rule) && Cat.isIsomorphism (rightMorphism rule) then
      (productions, (name, rule):predicates)
    else
      ((name, rule):productions, predicates)


-- draw state space graph -------------------------------------------------------------
drawStateSpace :: GraphState -> Maybe (Double,Double,Double,Double) -> Maybe [G.NodeId] -> Render ()
drawStateSpace state sq maybeGoodStates = drawGraph state sq nodeColors M.empty M.empty M.empty
  where
    g = stateGetGraph state
    allGoodStates = fromMaybe [] maybeGoodStates
    nodeColors = case maybeGoodStates of
                    Nothing            -> M.empty
                    Just allGoodStates ->
                        let (goodStates, badStates) = List.partition (`List.elem` allGoodStates) (G.nodeIds g)
                        in  (M.fromList $ map (\n -> (n,(0,1,0))) goodStates)
                            `M.union`
                            (M.fromList $ map (\n -> (n,(1,0,0))) badStates)




-- state space generation -------------------------------------------------------------------------------------------------------------------------------------------------------
exploreStateSpace :: DPO.MorphismsConfig (TGM.TypedGraphMorphism a b) -> Int -> DPO.Grammar (TGM.TypedGraphMorphism a b) -> TG.TypedGraph a b -> MVar (Space a b) -> IO (Int,Space a b)
exploreStateSpace conf maxDepth grammar graph ssMVar =
  let
    (productions, predicates) =
      splitPredicates (DPO.productions grammar)

    getInitialId =
      do
        (idx, _) <- SS.putState graph
        return idx

    initialSpace =
      SS.empty conf productions predicates
  in do
    (idx,space1) <- return $ SS.runStateSpaceBuilder getInitialId initialSpace
    spacex <- breadthFirstSearchIO maxDepth [graph] space1 ssMVar
    return (idx,spacex)



breadthFirstSearchIO :: Int -> [(TG.TypedGraph a b)] -> Space a b -> MVar (Space a b) -> IO (Space a b)
breadthFirstSearchIO 0 _ initialSpace ssMVar = return initialSpace
breadthFirstSearchIO _ [] initialSpace ssMVar = return initialSpace
breadthFirstSearchIO maxNum objs initialSpace ssMVar = do
  let ((newNum, newObjs), state) = SS.runStateSpaceBuilder (bfsStep maxNum objs) initialSpace
  empty <- isEmptyMVar ssMVar
  if empty then
    putMVar ssMVar state
  else
    do
      swapMVar ssMVar state
      return ()
  breadthFirstSearchIO newNum newObjs state ssMVar




-- | Runs a bread-first search on the state space, starting on the given object and limiting
-- the number of states to the given number.
breadthFirstSearch :: forall morph. DPO.DPO morph => Int -> [Cat.Obj morph] -> SS.StateSpaceBuilder morph ()
breadthFirstSearch maxNum [] = return ()
breadthFirstSearch 0 _ = return ()
breadthFirstSearch maxNum objs = do
  (newNum,newObjs) <- bfsStep maxNum objs
  breadthFirstSearch newNum newObjs


bfsStep :: forall morph. DPO.DPO morph => Int -> [Cat.Obj morph] -> SS.StateSpaceBuilder morph (Int,[Cat.Obj morph])
bfsStep maxNum (obj:node_list) = do
  (objIndex, _) <- SS.putState obj
  successors <- expandSuccessors' maxNum (objIndex,obj)
  let successors' = map (\(i,o,n) -> o) successors
  return (maxNum - length successors', node_list ++ successors')


-- | Finds all transformations of the given state with the productions of the HLR system being explored, adding them to the state space.
-- Returns a list of the successor states as @(index, object, isNew)@, where @isNew@ indicates that the state was not present in the state space before.
-- limits the number of matches applications to @maxNum@
expandSuccessors' :: forall morph. DPO.DPO morph => Int -> (Int, Cat.Obj morph) -> SS.StateSpaceBuilder morph [(Int, Cat.Obj morph, Bool)]
expandSuccessors' maxNum (index, object) =
  do
    prods <- SS.getProductions
    conf <- SS.getDpoConfig
    matches <- return . concat . map (\(name,prod) -> map (\match -> (name,prod,match)) (DPO.findApplicableMatches conf prod object)) $ prods
    (_,states) <- foldM f (maxNum, []) matches
    return states
  where
    f :: (Int, [(Int, Cat.Obj morph, Bool)]) -> (String, Production morph, morph) -> SS.StateSpaceBuilder morph  (Int, [(Int, Cat.Obj morph, Bool)])
    f (n,l) (name,prod,match) =
      if (n > 0) then
        do
          let object' = DPO.rewrite match prod
          (index', isNew) <- SS.putState object'
          SS.putTransition (index,index',name)
          return $
            if isNew then
              (n-1,(index',object',isNew):l)
            else
              (n,l)
      else
        return (0,l)
