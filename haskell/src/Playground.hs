{-# LANGUAGE OverloadedStrings #-}
module Playground where

import Language.Lojban.Core
import Language.Lojban.Dictionaries (englishDictionary)
import Language.Lojban.Canonicalization (basicSentenceCanonicalizer)
import Language.Eberban.Parser.Mercury.Samples as EberbanParserSamples
import Control.Applicative ((<$>))
import Control.Monad (sequence_)
import Data.Maybe (mapMaybe)
import Data.List.Ordered (nubSort)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Map as M
import qualified Data.Aeson as A
import System.Random (StdGen, mkStdGen)

-- See also: https://mw.lojban.org/papri/N-grams_of_Lojban_corpus

allGismu :: IO [Gismu]
allGismu = return $ map snd . M.toList . dictGismu $ englishDictionary

popularGismu :: IO [Gismu]
popularGismu = filter ((>=200) . gismuIRCFrequencyCount) <$> allGismu

popularGismuWords :: IO [T.Text]
popularGismuWords = map gismuText <$> popularGismu

loadGismuFromText :: Dictionary -> T.Text -> [Gismu]
loadGismuFromText dict t = mapMaybe lookup words where
    gismu = dictGismu dict
    lookup word = M.lookup word gismu
    words = nubSort . filter (/= "") . T.splitOn " " . T.replace "\n" " " $ t

loadGismuFromFile :: FilePath -> IO [Gismu]
loadGismuFromFile filePath = do
    loadGismuFromText englishDictionary <$> TIO.readFile filePath

terry :: IO [Gismu]
terry = loadGismuFromFile "/home/john/Temp/lojban/texts/terry.txt"

terryWords :: IO [T.Text]
terryWords = map gismuText <$> terry

canonicalizeString :: String -> Either String T.Text
canonicalizeString =  basicSentenceCanonicalizer . T.pack

samplesFromGenerator :: (StdGen -> (a, StdGen)) -> [a]
samplesFromGenerator gen = map applyGenerator [1..10000] where
    applyGenerator x = fst $ gen (mkStdGen x)

showSamplesFromGenerator :: (Show a) => (StdGen -> (a, StdGen)) -> String
showSamplesFromGenerator = unlines . nubSort . (map show) . samplesFromGenerator

displaySamplesFromGenerator :: (Show a) => (StdGen -> (a, StdGen)) -> IO ()
displaySamplesFromGenerator = putStrLn . showSamplesFromGenerator

saveDictionaries :: IO ()
saveDictionaries = sequence_ [saveDictionary "static/scripts/dictionaries/english.js" englishDictionary]

saveDictionary :: FilePath -> Dictionary -> IO ()
saveDictionary filePath dictionary = do
    let contents = "let dictionary=" `T.append` TL.toStrict (TLE.decodeUtf8 $ A.encode dictionary)
    TIO.writeFile filePath contents

displayEberbanParseSamples :: IO ()
displayEberbanParseSamples = EberbanParserSamples.displaySamples
