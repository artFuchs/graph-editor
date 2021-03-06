module Exec.Util 
  ( loadGrammar
  , loadSndOrderGrammar
  ) where

import Control.Monad
import qualified System.FilePath as FilePath
import System.Exit (exitFailure)

import           Category.TypedGraph                   (TypedGraphMorphism)
import           Category.TypedGraphRule               (RuleMorphism)
import           Exec.GlobalOptions
import           Abstract.Rewriting.DPO
import qualified XML.GGXReader                         as XML
import qualified XML.GPRReader.GXLReader  as GPR

import           Abstract.Constraint
import           Data.TypedGraph

loadGrammar :: GlobalOptions -> IO (Grammar (TypedGraphMorphism String String), String, [(String, String)])
loadGrammar globalOpts = do
  let file = inputFile globalOpts
  case FilePath.takeExtension file of
    ".ggx" -> do
      (fstOrderGG, _, _) <- XML.readGrammar file (useConstraints globalOpts) (morphismsConf globalOpts)
      ggName <- XML.readGGName (inputFile globalOpts)
      names <- XML.readNames (inputFile globalOpts)
      return (fstOrderGG, ggName, names)
    ".gps" -> do
      (fstOrderGG, names) <- GPR.readGrammar file
      let ggName = GPR.readGGName file
      return (fstOrderGG, ggName, names)
    ".vgg" -> do
      let ggName = FilePath.takeBaseName file
      fstOrderGG <- loadVGG file
      return (fstOrderGG, ggName, [])
    _ -> do
      putStrLn ("Input file has unsupported type: " ++ file)
      putStrLn "Only .ggx and .gps are supported."
      exitFailure


loadSndOrderGrammar :: GlobalOptions -> Bool
  -> IO (Grammar (TypedGraphMorphism a b), Grammar (RuleMorphism a b), String, [(String, String)])
loadSndOrderGrammar globalOpts shouldPrintSafetyNacs = do
  (fstOrderGG, sndOrderGG, printNewNacs) <- XML.readGrammar (inputFile globalOpts) (useConstraints globalOpts) (morphismsConf globalOpts)
  ggName <- XML.readGGName (inputFile globalOpts)
  names <- XML.readNames (inputFile globalOpts)
  when shouldPrintSafetyNacs $ do
    putStrLn "Adding minimal safety NACs to second-order rules..."
    mapM_ putStrLn (XML.showMinimalSafetyNacsLog printNewNacs)
    putStrLn "Added all minimal safety NACs!"
    putStrLn ""
  return (fstOrderGG, sndOrderGG, ggName, names)


loadVGG :: FilePath.FilePath -> IO (Grammar (TypedGraphMorphism String String))
loadVGG file = do
  contents <- readFile file
  let (start, constr, prod) = read contents
  let fstOrderGG = grammar start constr prod
  return fstOrderGG
