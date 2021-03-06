module GUI.Render.GraphDraw (
  drawGraph
, drawTypeGraph
, drawHostGraph
, drawRuleGraph
, drawNACGraph
, drawGraphHighlighting
) where

import qualified Data.Map as M
import qualified Data.Maybe as Maybe
import Control.Monad
import Graphics.Rendering.Cairo

import Data.Graphs hiding (null)

import GUI.Data.Info
import GUI.Data.GraphState
import GUI.Data.GraphicalInfo
import GUI.Data.Nac
import GUI.Render.Render
import GUI.Helper.GraphValidation
import GUI.Helper.Geometry

import qualified Graphics.Rendering.Pango as GRP
import qualified Graphics.Rendering.Pango.Cairo as GRPC
import qualified Graphics.Rendering.Pango.Layout as GRPL

type Color = (Double,Double,Double)
type SquareSelection = Maybe (Double,Double,Double,Double)

-- highlight colors for basic situations
selectColor = (0.29,0.56,0.85)
errorColor = (0.9,0.2,0.2)
bothColor = mixColors selectColor errorColor
lockedColor = (0.90,0.75,0.05)

mixColors :: Color -> Color -> Color
mixColors (r1,g1,b1) (r2,g2,b2) = ( (r1+r2)/2, (g1+g2)/2, (b1+b2)/2 )

drawSelectionBox:: SquareSelection -> Render()
drawSelectionBox sq = case sq of
  Just (x,y,w,h) -> do
    rectangle x y w h
    setSourceRGBA 0.29 0.56 0.85 0.5
    fill
    rectangle x y w h
    setSourceRGBA 0.29 0.56 0.85 1
    stroke
  Nothing -> return ()

drawGraph :: GraphState -> SquareSelection -> M.Map NodeId Color -> M.Map EdgeId Color -> M.Map NodeId Color -> M.Map EdgeId Color -> Render ()
drawGraph state sq nodeColors edgeColors nodeTextColors edgeTextColors = do
  let g = stateGetGraph state
      (nGI,eGI) = stateGetGI state
      (sNodes,sEdges) = stateGetSelected state
      z = stateGetZoom state
      (px,py) = stateGetPan state

  scale z z
  translate px py

  -- draw the edges
  forM (edges g) $ \e -> do
    let dstN = M.lookup (fromEnum . targetId $ e) nGI
        srcN = M.lookup (fromEnum . sourceId $ e) nGI
        egi  = M.lookup (fromEnum . edgeId   $ e) eGI
        info = infoVisible $ edgeInfo e
        (highlight, color) = case (edgeId e `elem` sEdges, M.lookup (edgeId e) edgeColors) of
            (False,Nothing) -> (False, (0,0,0))
            (False,Just c)  -> (True, c)
            (True, _) -> (True, selectColor)
            --(True, Just c)  -> (True, mixColors selectColor c)
        (highlightText, textColor) = Maybe.fromMaybe (False,(0,0,0)) $ (\a -> (True, a)) <$> M.lookup (edgeId e) edgeTextColors
    case (egi, srcN, dstN) of
      (Just gi, Just src, Just dst) -> renderEdge gi info src dst highlight color highlightText textColor
      _ -> return ()

  -- draw the nodes
  forM (nodes g) $ \n -> do
    let ngi = M.lookup (fromEnum . nodeId $ n) nGI
        info = infoVisible $ nodeInfo n
        (highlight, color) = case (nodeId n `elem` sNodes, M.lookup (nodeId n) nodeColors) of
            (False,Nothing) -> (False, (0,0,0))
            (False, Just c) -> (True, c)
            (True, Nothing) -> (True, selectColor)
            (True, Just c)  -> (True, mixColors selectColor c)
        (highlightText, textColor) = Maybe.fromMaybe (False,(0,0,0)) $ (\a -> (True, a)) <$> M.lookup (nodeId n) nodeTextColors
    case (ngi) of
      Just gi -> renderNode gi info highlight color highlightText textColor
      Nothing -> return ()

  drawSelectionBox sq

-- draw a typegraph in the canvas
-- if there are nodes or edges with same names, then highlight them as errors
-- if any element is selected, highlight it as selected
drawTypeGraph :: GraphState -> SquareSelection -> Render ()
drawTypeGraph state sq = drawGraph state sq nodeColors edgeColors M.empty M.empty
  where
    g = stateGetGraph state
    cg = nameConflictGraph g
    edgeColors = M.fromList $ map (\e -> (edgeId e, errorColor)) $ filter (not . edgeInfo) (edges cg)
    nodeColors = M.fromList $ map (\n -> (nodeId n, errorColor)) $ filter (not . nodeInfo) (nodes cg)

-- draw a typed graph
-- if there are nodes or edges not correctly typed, highlight them as errors
-- if any element is selected, highlight it as selected
drawHostGraph :: GraphState -> SquareSelection -> Graph Info Info -> Render ()
drawHostGraph state sq tg = drawGraph state sq nodeColors edgeColors M.empty M.empty
  where
    g = stateGetGraph state
    vg = correctTypeGraph g tg
    edgeColors = M.fromList $ map (\e -> (edgeId e, errorColor)) $ filter (not . edgeInfo) (edges vg)
    nodeColors = M.fromList $ map (\n -> (nodeId n, errorColor)) $ filter (not . nodeInfo) (nodes vg)

-- draw a rulegraph
-- similar to drawHostGraph, but draws bold texts to indicate operations
drawRuleGraph :: GraphState -> SquareSelection -> Graph Info Info -> Render ()
drawRuleGraph state sq tg = drawGraph state sq nodeColors edgeColors nodeTextColors edgeTextColors
  where
    g = stateGetGraph state
    (nGI,eGI) = stateGetGI state
    vg = correctTypeGraph g tg
    ovg = opValidationGraph g
    edgeColors = (M.fromList $ map (\e -> (edgeId e, errorColor)) $ filter (not . edgeInfo) (edges vg))
                 `M.union`
                 (M.fromList $ map (\e -> (edgeId e, errorColor)) $ filter (not . edgeInfo) (edges ovg))
                 `M.union`
                 edgeTextColors
    nodeColors = (M.fromList $ map (\n -> (nodeId n, errorColor)) $ filter (not . nodeInfo) (nodes vg))
                 `M.union`
                 (M.fromList $ map (\n -> (nodeId n, errorColor)) $ filter (not . nodeInfo) (nodes ovg))
                 `M.union`
                 nodeTextColors
    edgeTextColors = M.fromList $ Maybe.catMaybes
                                $ map (\e -> case infoOperation (edgeInfo e) of
                                                Create -> Just (edgeId e, createColor)
                                                Delete -> Just (edgeId e, deleteColor)
                                                _ -> Nothing)
                                  (edges g)
    nodeTextColors = M.fromList $ Maybe.catMaybes
                                $ map (\n -> case infoOperation (nodeInfo n) of
                                                Create -> Just (nodeId n, createColor)
                                                Delete -> Just (nodeId n, deleteColor)
                                                _ -> Nothing)
                                  (nodes g)
    createColor = (0.12, 0.48, 0.10)
    deleteColor = (0.17, 0.28, 0.77)

-- draw a nac
-- it highlights elements of the lhs part of the rule with yellow shadows
-- and highlights merged elements of the lhs part of the rule with green shadows
drawNACGraph :: GraphState -> SquareSelection -> Graph Info Info -> MergeMapping -> Render ()
drawNACGraph state sq tg (nM,eM) = drawGraph state sq nodeColors edgeColors M.empty M.empty
  where
    g = stateGetGraph state
    vg = correctTypeGraph g tg
    nodeColors =  (M.fromList $ map (\n -> (nodeId n, errorColor)) $ filter (not . nodeInfo) (nodes vg))
                  `M.union`
                  (M.fromList $ map (\n -> (nodeId n, if isNodeMerged n then mergedColor else lockedColor)) $ filter (infoLocked . nodeInfo) (nodes g))
    edgeColors =  (M.fromList $ map (\e -> (edgeId e, errorColor)) $ filter (not . edgeInfo) (edges vg))
                  `M.union`
                  (M.fromList $ map (\e -> (edgeId e, if isEdgeMerged e then mergedColor else lockedColor)) $ filter (infoLocked . edgeInfo) (edges g))
    mergedColor = (0.28,0.70,0.09)
    isNodeMerged n = M.size (M.filter (== (nodeId n)) nM) > 1
    isEdgeMerged e = M.size (M.filter (== (edgeId e)) eM) > 1

-- draw a graph highlighting elements of the lhs part of the rule with yellow shadows
drawGraphHighlighting :: GraphState -> SquareSelection -> ([NodeId],[EdgeId]) -> Render ()
drawGraphHighlighting state sq (nList,eList) = drawGraph state sq nodeColors edgeColors M.empty M.empty
  where
    g = stateGetGraph state
    nodeColors = M.fromList $ map (\n -> (n, lockedColor)) $ filter (\n -> n `elem` nList) (nodeIds g)
    edgeColors = M.fromList $ map (\e -> (e, lockedColor)) $ filter (\e -> e `elem` eList) (edgeIds g)
