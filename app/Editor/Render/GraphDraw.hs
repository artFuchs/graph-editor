module Editor.Render.GraphDraw (
  drawTypeGraph
, drawHostGraph
, drawRuleGraph
, drawRuleSideGraph
) where

import qualified Data.Map as M
import Control.Monad
import Graphics.Rendering.Cairo

import Data.Graphs

import Editor.Data.Info
import Editor.Data.EditorState
import Editor.Data.GraphicalInfo
import Editor.Render.Render
import Editor.Helper.GraphValidation

import Graphics.Rendering.Pango as GRP
import Graphics.Rendering.Pango.Cairo as GRPC
import Graphics.Rendering.Pango.Layout as GRPL
import Editor.Helper.Geometry

-- draw a graph in the canvas --------------------------------------------------
drawTypeGraph :: EditorState -> Maybe (Double,Double,Double,Double)-> Render ()
drawTypeGraph (g, (nGI,eGI), (sNodes, sEdges), z, (px,py)) sq = do
  scale z z
  translate px py

  let selectColor = (0.29,0.56,0.85)
      errorColor = (0.9,0.2,0.2)
      bothColor = (0.47,0.13,0.87)

  let cg = nameConflictGraph g


  -- draw the edges
  forM (edges g) (\e -> do
    let dstN = M.lookup (fromEnum . targetId $ e) nGI
        srcN = M.lookup (fromEnum . sourceId $ e) nGI
        egi  = M.lookup (fromEnum . edgeId   $ e) eGI
        selected = (edgeId e) `elem` sEdges
        conflict = case lookupEdge (edgeId e) cg of
          Just e' -> not $ edgeInfo e'
          Nothing -> True
        shadowColor = case (selected, conflict) of
          (False,False) -> (0,0,0)
          (False,True) -> errorColor
          (True,False) -> selectColor
          (True,True) -> bothColor
    case (egi, srcN, dstN) of
      (Just gi, Just src, Just dst) -> renderEdge gi (infoLabel $ edgeInfo e) src dst (selected || conflict) shadowColor False (0,0,0)
      _ -> return ())

  -- draw the nodes
  forM (nodes g) (\n -> do
    let ngi = M.lookup (fromEnum . nodeId $ n) nGI
        selected = (nodeId n) `elem` (sNodes)
        conflict = case lookupNode (nodeId n) cg of
          Just n' -> not $ nodeInfo n'
          Nothing -> True
        shadowColor = case (selected, conflict) of
          (False,False) -> (0,0,0)
          (False,True) -> errorColor
          (True,False) -> selectColor
          (True,True) -> bothColor
        info = infoLabel $ nodeInfo n
    case (ngi) of
      Just gi -> renderNode gi info (selected || conflict) shadowColor False (0,0,0)
      Nothing -> return ())

  -- draw the selectionBox
  drawSelectionBox sq
  return ()

drawHostGraph :: EditorState -> Maybe (Double,Double,Double,Double) -> Graph String String -> Render ()
drawHostGraph (g, (nGI,eGI), (sNodes, sEdges), z, (px,py)) sq tg = do
  scale z z
  translate px py

  -- specify colors for select and error
  let selectColor = (0.29,0.56,0.85)
      errorColor = (0.9,0.2,0.2)
      bothColor = (0.47,0.13,0.87)

  let vg = correctTypeGraph g tg
  -- draw the edges
  forM (edges g) (\e -> do
    let dstN = M.lookup (fromEnum . targetId $ e) nGI
        srcN = M.lookup (fromEnum . sourceId $ e) nGI
        egi  = M.lookup (fromEnum . edgeId   $ e) eGI
        selected = (edgeId e) `elem` sEdges
        typeError = case lookupEdge (edgeId e) vg of
                      Just e' -> not $ edgeInfo e'
                      Nothing -> True
        color = case (selected,typeError) of
                 (False,False) -> (0,0,0)
                 (False,True) -> errorColor
                 (True,False) -> selectColor
                 (True,True) -> bothColor
    case (egi, srcN, dstN) of
      (Just gi, Just src, Just dst) -> renderEdge gi (infoLabel (edgeInfo e)) src dst (selected || typeError) color False (0,0,0)
      _ -> return ())

  -- draw the nodes
  forM (nodes g) (\n -> do
    let ngi = M.lookup (fromEnum . nodeId $ n) nGI
        selected = (nodeId n) `elem` (sNodes)
        info = nodeInfo n
        label = infoLabel info
        typeError = case lookupNode (nodeId n) vg of
                      Just n' -> not $ nodeInfo n'
                      Nothing -> True
        color = case (selected,typeError) of
                  (False,False) -> (0,0,0)
                  (False,True) -> errorColor
                  (True,False) -> selectColor
                  (True,True) -> bothColor
    case (ngi) of
      Just gi -> renderNode gi label (selected || typeError) color False (0,0,0)
      Nothing -> return ())

  -- draw the selectionBox
  drawSelectionBox sq
  return ()

drawRuleGraph :: EditorState -> Maybe (Double,Double,Double,Double) -> Graph String String -> Render ()
drawRuleGraph (g, (nGI,eGI), (sNodes, sEdges), z, (px,py)) sq tg = do
  scale z z
  translate px py

  -- specify colors for select and error
  let selectColor = (0.29,0.56,0.85)
      errorColor = (0.9,0.2,0.2)
      bothColor = (0.47,0.13,0.87)
      createColor = (0.12, 0.48, 0.10)
      deleteColor = (0.17, 0.28, 0.77)

  let vg = correctTypeGraph g tg
  let ovg = opValidationGraph g

  -- draw the edges
  forM (edges g) (\e -> do
    let dstN = M.lookup (fromEnum . targetId $ e) nGI
        srcN = M.lookup (fromEnum . sourceId $ e) nGI
        egi  = M.lookup (fromEnum . edgeId   $ e) eGI
        info = infoVisible (edgeInfo e)
        selected = (edgeId e) `elem` sEdges
        typeError = case lookupEdge (edgeId e) vg of
                      Just e' -> not $ edgeInfo e'
                      Nothing -> True
        operationError = case lookupEdge (edgeId e) ovg of
                          Just e' -> not $ edgeInfo e'
                          Nothing -> True
        color = case (selected,typeError || operationError) of
                 (False,False) -> (0,0,0)
                 (False,True) -> errorColor
                 (True,False) -> selectColor
                 (True,True) -> bothColor
        (highlight, textColor) = case (infoOperation (edgeInfo e)) of
          "new" -> (True, createColor)
          "del" -> (True, deleteColor)
          ""    -> (False, (0,0,0))
          _     -> (True, errorColor)
    case (egi, srcN, dstN) of
      (Just gi, Just src, Just dst) -> renderEdge gi info src dst (selected || typeError || operationError) color highlight textColor
      _ -> return ())

  -- draw the nodes
  forM (nodes g) (\n -> do
    let ngi = M.lookup (fromEnum . nodeId $ n) nGI
        selected = (nodeId n) `elem` (sNodes)
        info = nodeInfo n
        label = infoVisible info
        typeError = case lookupNode (nodeId n) vg of
                      Just n' -> not $ nodeInfo n'
                      Nothing -> True
        color = case (selected,typeError) of
                  (False,False) -> (0,0,0)
                  (False,True) -> errorColor
                  (True,False) -> selectColor
                  (True,True) -> bothColor
        (highlight, textColor) = case (infoOperation info) of
          "new" -> (True, createColor)
          "del" -> (True, deleteColor)
          ""    -> (False, (0,0,0))
          _     -> (True, errorColor)
    case (ngi) of
      Just gi -> renderNode gi label (selected || typeError) color highlight textColor
      Nothing -> return ())

  drawSelectionBox sq
  return ()

drawRuleSideGraph :: EditorState -> Maybe (Double,Double,Double,Double) -> Graph String String -> Render ()
drawRuleSideGraph (g, (nGI,eGI), (sNodes, sEdges), z, (px,py)) sq k = do
  scale z z
  translate px py

  -- specify colors for select and error
  let selectColor = (0.29, 0.56, 0.85)
      errorColor =  (0.90, 0.20, 0.20)
      bothColor =   (0.47, 0.13, 0.87)
      (idr, idg, idb) = (0.5,0.5,0.5)--(0.57, 0.47, 0)

  -- draw the edges
  forM (edges g) (\e -> do
    let dstN = M.lookup (fromEnum . targetId $ e) nGI
        srcN = M.lookup (fromEnum . sourceId $ e) nGI
        egi  = M.lookup (fromEnum . edgeId   $ e) eGI
        info = infoLabel (edgeInfo e)
        shouldDrawId = case lookupEdge (edgeId e) k of
                        Just e' -> True
                        Nothing -> False
    case (egi, srcN, dstN) of
      (Just gi, Just src, Just dst) -> do
          renderEdge gi (info) src dst False (0,0,0) False (0,0,0)
          if shouldDrawId
            then do
              let (ae,de) = cPosition gi
                  (x1, y1) = position src
                  (x2, y2) = position dst
                  ang = angle (x1,y1) (x2,y2)
                  pos = pointAt (ae+ang) de (midPoint (x1,y1) (x2,y2))
              pL <- GRPC.createLayout (show (edgeId e))
              desc <- liftIO $ GRP.fontDescriptionFromString "Sans Bold 10"
              liftIO $ GRPL.layoutSetFontDescription pL (Just desc)
              setSourceRGB idr idg idb
              moveTo (fst pos) (snd pos)
              showLayout pL
            else return ()
      _ -> return ())

  -- draw the nodes
  forM (nodes g) (\n -> do
    let ngi = M.lookup (fromEnum . nodeId $ n) nGI
        label = infoLabel (nodeInfo n)
        shouldDrawId = case lookupNode (nodeId n) k of
                          Just _ -> True
                          Nothing -> False
    case (ngi) of
      Just gi -> do
          renderNode gi label False (0,0,0) False (0,0,0)
          if shouldDrawId
            then do
              let pos = addPoint (position gi) (-(fst . dims $ gi), -(snd . dims $ gi))
              pL <- GRPC.createLayout (show (nodeId n))
              desc <- liftIO $ GRP.fontDescriptionFromString "Sans Bold 10"
              liftIO $ GRPL.layoutSetFontDescription pL (Just desc)
              setSourceRGB idr idg idb
              moveTo (fst pos) (snd pos)
              showLayout pL
            else return ()
      Nothing -> return ())

  drawSelectionBox sq
  return ()


drawSelectionBox:: Maybe (Double,Double,Double,Double) -> Render()
drawSelectionBox sq = case sq of
  Just (x,y,w,h) -> do
    rectangle x y w h
    setSourceRGBA 0.29 0.56 0.85 0.5
    fill
    rectangle x y w h
    setSourceRGBA 0.29 0.56 0.85 1
    stroke
  Nothing -> return ()