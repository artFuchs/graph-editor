module GUI.Data.DiaGraph(
  DiaGraph
, empty
, isDiaGraphEqual
, diagrDisjointUnion
, diagrUnion
, diagrSubtract
, getEdgePosition
, adjustDiagrPosition
)where

import qualified Data.Map as M

import Data.Graphs hiding (null, empty)
import qualified Data.Graphs as G

import GUI.Data.GraphicalInfo
import GUI.Data.Info hiding (empty)
import GUI.Helper.Geometry

-- |DiaGraph
-- A pair containing a graph and it's graphical information
type DiaGraph = (Graph Info Info, GraphicalInfo)

empty :: DiaGraph
empty = (G.empty, (M.empty, M.empty))

isDiaGraphEqual :: DiaGraph -> DiaGraph -> Bool
isDiaGraphEqual (g1,gi1) (g2,gi2) = g1 == g2 && nodesGiEq && edgesGiEq
  where
    nodesGiEq = sameLength (M.elems $ fst gi1) (M.elems $ fst gi2) && all (\(x,y) -> x == y) (zip (M.elems $ fst gi1) (M.elems $ fst gi2))
    edgesGiEq = sameLength (M.elems $ snd gi1) (M.elems $ snd gi2) && all (\(x,y) -> x == y) (zip (M.elems $ snd gi1) (M.elems $ snd gi2))
    sameLength l1 l2 = length l1 == length l2


-- converts and association list to the respective function
assocToFunc :: (Eq a) => [(a,a)] -> a -> a
assocToFunc l = foldr (\(x,y) m -> (\z -> if z == x then y else (m z)) ) id l

-- disjoint union between two DiaGraphs
diagrDisjointUnion :: DiaGraph -> DiaGraph -> DiaGraph
diagrDisjointUnion diagr1@(g1,(ngiM1,egiM1)) (g2,(ngiM2,egiM2)) = diagrUnion diagr1 (g2',(ngiM2',egiM2'))
  where
    -- associar novos ids aos elementos de g2
    newNids = zipWith (\n nid-> (nodeId n, nid)) (nodes g2) $ take (length $ nodes g2) (newNodes g1)
    newEids = zipWith (\e eid-> (edgeId e, eid)) (edges g2) $ take (length $ edges g2) (newEdges g1)
    fn = assocToFunc newNids
    fe = assocToFunc newEids
    ns2' = foldr (\n ns -> (Node (fn $ nodeId n) (nodeInfo n)):ns ) [] $ nodes g2
    es2' = foldr (\e es -> (Edge (fe $ edgeId e) (fn $ sourceId e) (fn $ targetId e) (edgeInfo e)):es ) [] $ edges g2
    g2' = fromNodesAndEdges ns2' es2'
    ngiM2' = M.foldrWithKey (\k a m -> M.insert (fromEnum . fn . toEnum $ k) a m) M.empty ngiM2
    egiM2' = M.foldrWithKey (\k a m -> M.insert (fromEnum . fe . toEnum $ k) a m) M.empty egiM2

-- diagraph union
diagrUnion :: DiaGraph -> DiaGraph -> DiaGraph
diagrUnion (g1,(ngiM1,egiM1)) (g2,(ngiM2,egiM2)) = (g3,(ngiM3,egiM3))
  where
    ns3 = concat [nodes g1, nodes g2]
    es3 = concat [edges g1, edges g2]
    g3 = fromNodesAndEdges ns3 es3
    ngiM3 = M.union ngiM1 ngiM2
    egiM3 = M.union egiM1 egiM2

-- subtract a diagraph dg2 from diagraph dg1
diagrSubtract :: DiaGraph -> DiaGraph -> DiaGraph
diagrSubtract (g1, (ngiM1, egiM1)) (g2, (ngiM2,egiM2)) = (g3,(ngiM3,egiM3))
  where
    eds3 = filter (\e -> notElem (edgeId e) (edgeIds g2)) $ edges g1
    nds3 = filter (\n -> (notElem (nodeId n) (nodeIds g2)) || isEssential (nodeId n)) $ nodes g1
    g3 = fromNodesAndEdges nds3 eds3
    ngiM3 = M.filterWithKey (\k a -> (NodeId k) `elem` nodeIds g3) ngiM1
    egiM3 = M.filterWithKey (\k a -> (EdgeId k) `elem` edgeIds g3) egiM1

    isEssential nid = nid `elem` (map sourceId eds3) || nid `elem` (map targetId eds3)


-- get edge position in cartesian coordinate system
getEdgePosition:: DiaGraph -> Edge Info -> (Double,Double)
getEdgePosition (g,(nodesGi, edgesGi)) e = pos
  where
    eid = edgeId e
    gi = getEdgeGI (fromEnum $ eid) edgesGi
    srcPos = position . getNodeGI (fromEnum $ sourceId e) $ nodesGi
    dstPos = position . getNodeGI (fromEnum $ targetId e) $ nodesGi
    (ae, de) = cPosition gi
    pos = if sourceId e /= targetId e
      then
        let pmid = midPoint srcPos dstPos
            (ang, dist) = toPolarFrom srcPos dstPos
        in pointAt (ae+ang) de pmid
      else
        pointAt ae de srcPos

adjustDiagrPosition :: DiaGraph -> DiaGraph
adjustDiagrPosition (g, (ngiM, egiM)) = (g,(ngiM',egiM))
  where
    allPositions = concat [map position (M.elems ngiM), map (getEdgePosition (g,(ngiM, egiM))) (edges g)]
    minX = minimum $ map fst allPositions
    minY = minimum $ map snd allPositions
    upd (a,b) = (20+a-minX, 20+b-minY)
    ngiM' = M.map (\gi -> gi {position = (upd $ position gi)}) ngiM
