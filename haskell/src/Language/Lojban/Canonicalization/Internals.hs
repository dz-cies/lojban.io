{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}

module Language.Lojban.Canonicalization.Internals
( StructuredSelbri
, StructuredTerm
, ExtraTerm
, StructuredBridi
, normalizeText
, canonicalizeText
, canonicalizeParsedText
, canonicalizeParsedBridi
, canonicalizeParsedTerm
, retrieveSimpleBridi
, extractSimpleBridi
, retrieveStructuredBridi
) where

import Language.Lojban.Core
import Language.Lojban.Parsing (parseText)
import Language.Lojban.Presentation (displayCanonicalBridi)
import Language.Lojban.Dictionaries (englishDictionary)
import Util (headOrDefault, isContiguousSequence, concatET, unwordsET)
import Control.Applicative (liftA2)
import Control.Exception (assert)
import Control.Monad (mplus)
import Data.List (partition, intersperse)
import qualified Data.Text as T
import qualified Data.Map as M
import qualified Language.Lojban.Parser.ZasniGerna as ZG

------------------------- ----------------------- Sentence canonicalizers
--TODO: check whether se/te/ve/xe are left-associative or right-associative
--ZasniGerna documentation: https://hackage.haskell.org/package/zasni-gerna-0.0.7/docs/Language-Lojban-Parser-ZasniGerna.html

---------- Types
type StructuredSelbri = ZG.Text
type StructuredTerm = ZG.Text
type ExtraTerm = ZG.Text
type StructuredBridi = (StructuredSelbri, [(Int, StructuredTerm)], [ExtraTerm])

---------- Handle place tags (fa/fe/fi/fo/fu)
handlePlaceTags :: StructuredBridi -> Either String StructuredBridi
handlePlaceTags (selbri, [], extraTerms) = Right $ (selbri, [], extraTerms)
handlePlaceTags (selbri, terms, extraTerms) = assert (isContiguousSequence $ map fst terms) $ Right (selbri, f firstPosition terms, extraTerms) where
    firstPosition = fst $ head terms
    f :: Int -> [(Int, StructuredTerm)] -> [(Int, StructuredTerm)]
    f _ [] = []
    f defaultPosition (h:t) = let (tag, term) = retrieveTag (snd h)
                                  position = case tag of Just x -> retrievePosition x; Nothing -> defaultPosition
                              in (position, term) : f (position+1) t
    retrievePosition :: String -> Int
    retrievePosition "fa" = 1
    retrievePosition "fe" = 2
    retrievePosition "fi" = 3
    retrievePosition "fo" = 4
    retrievePosition "fu" = 5
    retrieveTag :: ZG.Text -> (Maybe String, ZG.Text)
    retrieveTag (ZG.Tag (ZG.FA x) y) = (Just x, y)
    retrieveTag x = (Nothing, x)

---------- Handle place permutations (se/te/ve/xe)
swapTerms :: Int -> Int -> [(Int, StructuredTerm)] -> [(Int, StructuredTerm)]
swapTerms x y terms = assert (x /= y) $ map f terms where
    f (k, t) = (if k == x then y else if k == y then x else k, t)
swapTerms2 :: String -> [(Int, StructuredTerm)] -> [(Int, StructuredTerm)]
swapTerms2 "se" = swapTerms 1 2
swapTerms2 "te" = swapTerms 1 3
swapTerms2 "ve" = swapTerms 1 4
swapTerms2 "xe" = swapTerms 1 5

handlePlacePermutations :: StructuredBridi -> Either String StructuredBridi
handlePlacePermutations (ZG.Tanru brivlaList, terms, extraTerms) = (, terms, extraTerms) <$> ZG.BRIVLA <$> T.unpack <$> retrieveTanruFromBrivlaList brivlaList
handlePlacePermutations (ZG.BRIVLA brivla, terms, extraTerms) = Right $ (ZG.BRIVLA brivla, terms, extraTerms)
handlePlacePermutations (ZG.GOhA brivla, terms, extraTerms) = Right $ (ZG.GOhA brivla, terms, extraTerms)
handlePlacePermutations (ZG.Prefix (ZG.SE x) y, terms, extraTerms) = do
    (selbri, terms2, extraTerms) <- handlePlacePermutations (y, terms, extraTerms)
    return $ (selbri, swapTerms2 x terms2, extraTerms)
handlePlacePermutations (ZG.Prefix (ZG.JAI x) y, terms, extraTerms) = do
    (selbri, terms2, extraTerms) <- handlePlacePermutations (y, terms, extraTerms)
    return $ (insertPrefixIntoStructuredSelbri (x ++ " ") selbri, terms2, extraTerms)
handlePlacePermutations x = Left $ "unrecognized pattern in function handlePlacePermutations: " ++ show x

handleScalarNegation :: StructuredBridi -> Either String StructuredBridi
handleScalarNegation (ZG.Prefix (ZG.NAhE nahe) (ZG.BRIVLA brivla), terms, extraTerms) = Right $ (ZG.BRIVLA $ nahe ++ " " ++ brivla, terms, extraTerms)
handleScalarNegation x = Right $ x

---------- Append extra tag to structured bridi
appendExtraTagToStructuredBridi :: ZG.Text -> StructuredBridi -> StructuredBridi
appendExtraTagToStructuredBridi tag (x, y, z) = (x, y, tag : z)

insertPrefixIntoStructuredSelbri :: String -> ZG.Text -> ZG.Text
insertPrefixIntoStructuredSelbri prefix (ZG.BRIVLA brivla) = ZG.BRIVLA $ prefix ++ brivla
-- TODO: also handle TANRU, GOhA, etc.

---------- Construct structured bridi from terms
constructStructuredBridiFromTerms :: StructuredSelbri -> [StructuredTerm] -> StructuredBridi
constructStructuredBridiFromTerms selbri terms = (selbri, (zip [1..] mainTerms), extraTerms) where
    isExtraTerm :: ZG.Text -> Bool
    isExtraTerm (ZG.TagKU (ZG.NA x) _) = True
    isExtraTerm (ZG.TagKU (ZG.BAI x) _) = True
    isExtraTerm (ZG.TagKU (ZG.FIhO x y z) _) = True
    isExtraTerm (ZG.TagKU (ZG.PrefixTag x y) a) = isExtraTerm (ZG.TagKU y a)
    isExtraTerm (ZG.Tag (ZG.NA x) _) = True
    isExtraTerm (ZG.Tag (ZG.BAI x) _) = True
    isExtraTerm (ZG.Tag (ZG.FIhO x y z) _) = True
    isExtraTerm (ZG.Tag (ZG.PrefixTag x y) a) = isExtraTerm (ZG.Tag y a)
    isExtraTerm _ = False
    (extraTerms, mainTerms) = partition isExtraTerm terms

---------- Retrieve structured bridi
retrieveStructuredBridi :: ZG.Text -> Either String StructuredBridi
------- without x1
-- pu prami / pu se prami / pu ca ba prami / pu ca ba se prami (also pu go'i / pu se go'i / ...)
retrieveStructuredBridi (ZG.Tag x y) = appendExtraTagToStructuredBridi (ZG.TagKU x (ZG.Term "ku")) <$> retrieveStructuredBridi y
-- pu prami do / pu se prami do / pu ca ba prami do / pu ca ba se prami do (also pu go'i do / pu se go'i do / ...)
retrieveStructuredBridi (ZG.BridiTail (ZG.Tag x y) z) = appendExtraTagToStructuredBridi (ZG.TagKU x (ZG.Term "ku")) <$> retrieveStructuredBridi (ZG.BridiTail y z)
-- mutce prami
retrieveStructuredBridi (ZG.Tanru brivlaList) = (, [], []) <$> ZG.BRIVLA <$> T.unpack <$> retrieveTanruFromBrivlaList brivlaList
-- prami
retrieveStructuredBridi (ZG.BRIVLA brivla) = Right $ (ZG.BRIVLA brivla, [], [])
-- go'i
retrieveStructuredBridi (ZG.GOhA brivla) = Right $ (ZG.GOhA brivla, [], [])
-- se prami / se go'i
retrieveStructuredBridi (ZG.Prefix x y) = Right $ (ZG.Prefix x y, [], [])
-- prami do / se prami do (also go'i do / se go'i do) / cmene lo mlatu gau mi
retrieveStructuredBridi (ZG.BridiTail selbri (ZG.Terms terms _)) = Right $ (selbri, zip [2..] regularTerms, specialTerms) where
    regularTerms = filter (not . isSpecialTerm) terms
    specialTerms = filter isSpecialTerm terms
    isSpecialTerm term = case term of
        ZG.Tag x y -> True
        ZG.TagKU x y -> True
        _ -> False
-- gau mi cmene lo mlatu
retrieveStructuredBridi (ZG.Bridi (ZG.Terms ((ZG.Tag x y):more_terms) terms_terminator) z) = appendExtraTagToStructuredBridi (ZG.Tag x y) <$> retrieveStructuredBridi (ZG.Bridi (ZG.Terms more_terms terms_terminator) z)
retrieveStructuredBridi (ZG.Bridi (ZG.Terms [] ZG.NT) (ZG.BridiTail x y)) = retrieveStructuredBridi (ZG.BridiTail x y)
------- with x1
-- mi prami / mi pu ku ca ku prami
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms _) (ZG.Tanru brivlaList)) = constructStructuredBridiFromTerms <$> (ZG.BRIVLA <$> T.unpack <$> retrieveTanruFromBrivlaList brivlaList) <*> (Right $ terms)
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms _) (ZG.BRIVLA brivla)) = Right $ constructStructuredBridiFromTerms (ZG.BRIVLA brivla) terms
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms terms_t) (ZG.Tag x y)) = appendExtraTagToStructuredBridi (ZG.TagKU x (ZG.Term "ku")) <$> retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms terms_t) y)
-- mi go'i / mi pu ku ca ku go'i
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms _) (ZG.GOhA brivla)) = Right $ constructStructuredBridiFromTerms (ZG.GOhA brivla) terms
-- mi se prami / mi pu ku ca ku se prami
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms _) (ZG.Prefix x y)) = Right $ constructStructuredBridiFromTerms (ZG.Prefix x y) terms
-- mi pu ku ca ku prami do / mi pu ku ca ku se prami do
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms1 terms1_t) (ZG.BridiTail (ZG.Tag x y) z)) = appendExtraTagToStructuredBridi (ZG.TagKU x (ZG.Term "ku")) <$> retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms1 terms1_t) (ZG.BridiTail y z))
-- mi prami do / mi se prami do 
retrieveStructuredBridi (ZG.Bridi (ZG.Terms terms1 _) (ZG.BridiTail selbri (ZG.Terms terms2 _))) = Right $ constructStructuredBridiFromTerms selbri (terms1 ++ terms2)
------- invalid
retrieveStructuredBridi x = Left $ "unrecognized pattern in function retrieveStructuredBridi: " ++ show x

---------- Convert structured bridi to simple bridi
-- The structured bridi must already have correct place structure (no place tags, no place reordering)
convertStructuredBridi :: Bool -> StructuredBridi -> Either String SimpleBridi
convertStructuredBridi xu (selbri, terms, extraTerms) = do
    selbri2 <- convertStructuredSelbri selbri
    terms2 <- convertStructuredTerms terms
    extraTerms2 <- convertExtraTerms extraTerms
    return $ SimpleBridi xu selbri2 terms2 extraTerms2

convertStructuredSelbri :: StructuredSelbri -> Either String T.Text
convertStructuredSelbri (ZG.BRIVLA brivla) = Right $ T.pack brivla
convertStructuredSelbri (ZG.GOhA brivla) = Right $ T.pack brivla
convertStructuredSelbri (ZG.Prefix (ZG.SE x) y) = concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredSelbri y]
convertStructuredSelbri x = Left $ "Unrecognized pattern for structured selbri: " ++ show x

convertStructuredTerms :: [(Int, StructuredTerm)] -> Either String [T.Text]
convertStructuredTerms terms = do
    let terms2 = map (fmap convertStructuredTerm) terms :: [(Int, Either String T.Text)]
    let terms3 = map (\(i, v) -> (i,) <$> v) terms2 :: [Either String (Int, T.Text)]
    terms4 <- foldr (liftA2 (:)) (Right []) terms3 :: Either String [(Int, T.Text)]
    let terms5 = filter ((/= "zo'e") . snd) terms4 :: [(Int, T.Text)]
    let lastTermNumber = if null terms5 then 0 else maximum (map fst terms5)
    let retrieveTerm i = headOrDefault (T.pack "") $ map snd $ filter ((== i) . fst) terms5
    return $ map retrieveTerm [1..lastTermNumber]

convertLinkargs :: ZG.Linkargs -> Either String T.Text
convertLinkargs (ZG.BE (ZG.Init x) y _) = concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredTerm y, Right $ T.pack " be'o"]
convertLinkargs (ZG.BEI (ZG.Init x) y z _) = concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredTerm y, Right $ T.pack " ", unwordsET beiArguments, Right $ T.pack " be'o"] where
    beiArguments :: [Either String T.Text]
    beiArguments = map convertArgument z
    convertArgument :: (ZG.Separator, ZG.Text) -> Either String T.Text
    convertArgument (ZG.Sep x, y) = concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredTerm y]
-- TODO: handle InitF

convertInitiator :: ZG.Initiator -> Either String T.Text
convertInitiator (ZG.Init x) = Right $ T.pack x
-- TODO: InitF, BInit, BInitF

convertRelative :: ZG.Relative -> Either String T.Text
convertRelative (ZG.NOI x y _) = concatET [convertInitiator x, Right $ T.pack " ", convertBridi y, Right $ " ku'o"]
convertRelative (ZG.GOI x y _) = concatET [convertInitiator x, Right $ T.pack " ", convertTerm y, Right $ " ge'u"]
convertRelative x = Left $ "Unrecognized pattern for convertRelative: " ++ show x

convertStructuredTerm :: StructuredTerm -> Either String T.Text
convertStructuredTerm (ZG.KOhA x) = Right $ T.pack x
convertStructuredTerm (ZG.Link x y) = concatET [convertStructuredTerm x, Right $ T.pack " ", convertLinkargs y]
convertStructuredTerm (ZG.BRIVLA x) = Right $ T.pack x
convertStructuredTerm (ZG.Tag (ZG.NA x) y) = convertStructuredTerm (ZG.Tag (ZG.TTags [ZG.NA x]) y)
convertStructuredTerm (ZG.Tag (ZG.BAI x) y) = convertStructuredTerm (ZG.Tag (ZG.TTags [ZG.BAI x]) y)
convertStructuredTerm (ZG.Tag (ZG.TTags tagsList) y) = concatET $ extractedTags ++ [Right $ T.pack " ", convertStructuredTerm y] where
    extractedTags :: [Either String T.Text]
    extractedTags = intersperse (Right $ T.pack " ") $ map extractTag tagsList
    extractTag :: ZG.Tag -> Either String T.Text
    extractTag (ZG.NA x) = Right $ T.pack x
    extractTag (ZG.BAI x) = Right $ case expandBai x of
        Just x' -> T.pack $ "fi'o " ++ x' ++ " fe'u"
        Nothing -> T.pack x
    extractTag x = Left $ "Unrecognized pattern for extractTag: " ++ show x
convertStructuredTerm (ZG.Rel x y) = concatET [convertStructuredTerm x, Right $ T.pack " ", convertRelative y]
convertStructuredTerm (ZG.GOhA x) = Right $ T.pack x
convertStructuredTerm (ZG.Prefix (ZG.NAhE x) (ZG.BRIVLA y)) = Right $ T.pack (x ++ " " ++ y)
convertStructuredTerm (ZG.Prefix (ZG.SE x) y) = insertPrefix <$> convertStructuredTerm y where
    insertPrefix = ((T.pack $ x ++ " ") `T.append`)
convertStructuredTerm (ZG.NU (ZG.Init x) y w) = convertStructuredTerm (ZG.NU (ZG.InitF x ZG.NF) y w)
convertStructuredTerm (ZG.NU (ZG.InitF x y) w z) = insertPrefix . insertSuffix <$> canonicalizeParsedBridi (y, w, z) where
    insertPrefix = ((T.pack $ x ++ " ") `T.append`)
    insertSuffix = (`T.append` " kei")
convertStructuredTerm (ZG.LE (ZG.Init x) ZG.NR number (ZG.Rel y z) t) = convertStructuredTerm $ ZG.Rel (ZG.LE (ZG.Init x) ZG.NR number y t) z
convertStructuredTerm (ZG.LE (ZG.Init x) ZG.NR number y _) = insertPrefix . insertSuffix <$> (insertNumber <*> convertStructuredTerm y) where
    insertNumber = canonicalizeNumber number >>= \case
        "" -> return id
        x -> return ((x `T.append` " ") `T.append`)
    insertPrefix = ((T.pack $ x ++ " ") `T.append`)
    insertSuffix = (`T.append` " ku")
convertStructuredTerm (ZG.LE (ZG.Init x) (ZG.RelSumti y) ZG.NQ z _) = unwordsET [Right $ T.pack x, convertBridi z, Right "ku pe", convertTerm y, Right "ge'u"]
convertStructuredTerm (ZG.Tanru xs) = unwordsET (map convertStructuredTerm xs)
convertStructuredTerm (ZG.Clause (ZG.ZO x)) = Right $ T.unwords ["lo'u", T.pack x, "le'u"]
convertStructuredTerm (ZG.Clause (ZG.LOhU x)) = Right $ T.unwords ["lo'u",  T.unwords $ map T.pack x, "le'u"]
convertStructuredTerm (ZG.LU (ZG.Init x) y term) = unwordsET [Right $ T.pack x, convertText y , Right $ "li'u"]
convertStructuredTerm (ZG.Con x connectives) = unwordsET $ convertStructuredTerm x : (map convertConnective connectives) where
    convertConnective :: (ZG.Connective, ZG.Text) -> Either String T.Text
    convertConnective (ZG.JOI x, y) = concatET [Right ".", Right $ T.pack x, Right " ", convertTerm y]
convertStructuredTerm (ZG.LAhE (ZG.Init x) ZG.NR y ZG.NT) = unwordsET $ [Right $ T.pack x, convertStructuredTerm y]
convertStructuredTerm x = Left $ "Unrecognized pattern for structured term: " ++ show x

convertExtraTerms :: [ExtraTerm] -> Either String [T.Text]
convertExtraTerms = mapM convertExtraTerm . expandExtraTerms

expandExtraTerms :: [ExtraTerm] -> [ExtraTerm]
expandExtraTerms = concatMap expandTerm where
    expandTerm :: ExtraTerm -> [ExtraTerm]
    expandTerm (ZG.TagKU (ZG.TTags tags) term) = map (`ZG.TagKU` term) tags
    expandTerm x = [x]

convertExtraTerm :: ExtraTerm -> Either String T.Text
convertExtraTerm (ZG.TagKU (ZG.NA x) _) = concatET [Right $ T.pack x, Right $ T.pack " ku"]
convertExtraTerm (ZG.TagKU (ZG.FIhO (ZG.Init _) y _) _) = concatET [Right $ T.pack "fi'o ", convertStructuredSelbri y, Right $ T.pack " fe'u ku"]
convertExtraTerm (ZG.Tag (ZG.NA x) text) = concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredTerm text, Right $ T.pack " ku"]
convertExtraTerm (ZG.Tag (ZG.FIhO (ZG.Init _) y _) text) = concatET [Right $ T.pack "fi'o ", convertStructuredSelbri y, Right $ T.pack " fe'u ", convertStructuredTerm text]
convertExtraTerm (ZG.TagKU (ZG.PrefixTag (ZG.SE x) (ZG.BAI y)) z) = case expandBai y of
    Just y' -> convertExtraTerm $ ZG.TagKU (ZG.FIhO (ZG.Init "fi'o") (ZG.Prefix (ZG.SE x) (ZG.BRIVLA y')) (ZG.Term "fe'u")) z
    Nothing -> concatET [Right $ T.pack x, Right $ T.pack " ", convertExtraTerm (ZG.TagKU (ZG.BAI y) z)]
convertExtraTerm (ZG.Tag (ZG.PrefixTag (ZG.SE x) (ZG.BAI y)) z) = case expandBai y of
    Just y' -> convertExtraTerm $ ZG.Tag (ZG.FIhO (ZG.Init "fi'o") (ZG.Prefix (ZG.SE x) (ZG.BRIVLA y')) (ZG.Term "fe'u")) z
    Nothing -> concatET [Right $ T.pack x, Right $ T.pack " ", convertExtraTerm (ZG.Tag (ZG.BAI y) z)]
convertExtraTerm (ZG.TagKU (ZG.BAI x) y) = case expandBai x of
    Just x' -> convertExtraTerm $ ZG.TagKU (ZG.FIhO (ZG.Init "fi'o") (ZG.BRIVLA x') (ZG.Term "fe'u")) y
    Nothing -> concatET [Right $ T.pack x, Right $ T.pack " ku"]
convertExtraTerm (ZG.Tag (ZG.BAI x) text) = case expandBai x of
    Just x' -> convertExtraTerm $ ZG.Tag (ZG.FIhO (ZG.Init "fi'o") (ZG.BRIVLA x') (ZG.Term "fe'u")) text
    Nothing -> concatET [Right $ T.pack x, Right $ T.pack " ", convertStructuredTerm text]
convertExtraTerm x = Left $ "Unrecognized pattern for convertExtraTerm: " ++ show x

canonicalizeNumber :: ZG.Mex -> Either String T.Text
canonicalizeNumber ZG.NQ = Right ""
canonicalizeNumber (ZG.P1 digit) = canonicalizeNumber (ZG.Ms [(ZG.P1 digit)] ZG.NT)
canonicalizeNumber (ZG.Ms digits ZG.NT) = concatET $ map convertDigit digits where
    convertDigit :: ZG.Mex -> Either String T.Text
    convertDigit (ZG.P1 x) = Right $ T.pack x
    convertDigit x = Left $ "Unrecognized pattern for convertDigit: " ++ show x
canonicalizeNumber x = Left $ "Unrecognized pattern for canonicalizeNumber: " ++ show x

-- TODO: add all BAI
compressedBai :: M.Map String String
compressedBai = M.fromList
    [ ("pi'o", "pilno")
    , ("zu'e", "zukte")
    , ("mu'i", "mukti")
    , ("gau", "gasnu")
    ]

expandBai :: String -> Maybe String
expandBai = (`M.lookup` compressedBai)

retrieveTanruFromBrivlaList :: [ZG.Text] -> Either String T.Text
retrieveTanruFromBrivlaList brivlaList = unwordsET $ convertStructuredSelbri <$> brivlaList

---------- Canonicalization
--TODO: canonicalize "do xu ciska" -> "xu do ciska"
canonicalizeText :: SentenceCanonicalizer
canonicalizeText sentence = parseText (normalizeText sentence) >>= canonicalizeParsedText

-- | Normalizes the text prior to parsing.
--
-- Useful for performing dirty hacks, such as blindly replacing "be fi" with "be zo'e bei, until
-- canonicalization of the corresponding construct is properly implement using the parse tree.
normalizeText :: T.Text -> T.Text
normalizeText = normalizeWords . applyHacks . normalizeApostrophes where
    normalizeApostrophes :: T.Text -> T.Text
    normalizeApostrophes = T.replace "’" "'"
    applyHacks :: T.Text -> T.Text
    applyHacks = T.replace " be fi " " be zo'e bei " . T.replace " befi " " be zo'e bei " . T.replace " befilo " " be zo'e bei lo "

-- | Normalizes individual words in the sentence.
--
-- For example, normalizes words starting with well-known rafsi: "seldunda" and "seldu'a" become "se dunda".
normalizeWords :: T.Text -> T.Text
normalizeWords = T.unwords . map normalizeWord . T.words where
    normalizeWord :: T.Text -> T.Text
    normalizeWord = normalizeSimpleRafsi
    normalizeSimpleRafsi :: T.Text -> T.Text
    normalizeSimpleRafsi = normalizePositionalRafsi "sel" "se" . normalizePositionalRafsi "ter" "te" . normalizePositionalRafsi "vel" "ve" . normalizePositionalRafsi "xel" "xe"
    -- | Normalizes single words starting with the given positional rafsi (sel, ter, vel or xel).
    normalizePositionalRafsi :: T.Text -> T.Text -> T.Text -> T.Text
    normalizePositionalRafsi positionalRafsiText positionalCmavoText word =
        case T.stripPrefix positionalRafsiText word of
            Nothing -> word
            Just wordWithStrippedRafsi -> positionalCmavoText `T.append` " " `T.append` (normalizeSingleRafsiWord wordWithStrippedRafsi)
    -- | If the word is a single rafsi mapping to a gismu, then converts it into the full gismu. Otherwise does nothing.
    --
    -- For example, "du'a" becomes "dunda", but "predu'a" remains the same.
    normalizeSingleRafsiWord :: T.Text -> T.Text
    normalizeSingleRafsiWord word = case M.lookup word (dictRafsi englishDictionary) of
        Nothing -> word
        Just gismu -> gismuText gismu

canonicalizeParsedText :: (ZG.Free, ZG.Text, ZG.Terminator) -> Either String T.Text
canonicalizeParsedText parsedText = (canonicalizeParsedTerm parsedText) `mplus` (canonicalizeParsedBridi parsedText)

canonicalizeParsedBridi :: (ZG.Free, ZG.Text, ZG.Terminator) -> Either String T.Text
canonicalizeParsedBridi parsedBridi = displayCanonicalBridi <$> (retrieveSimpleBridi parsedBridi)

extractSimpleBridi :: T.Text -> Either String SimpleBridi
extractSimpleBridi text = parseText text >>= retrieveSimpleBridi

retrieveSimpleBridi :: (ZG.Free, ZG.Text, ZG.Terminator) -> Either String SimpleBridi
retrieveSimpleBridi (free, text, terminator) = retrieveStructuredBridi text >>= handleScalarNegation >>= handlePlaceTags >>= handlePlacePermutations >>= convertStructuredBridi xu where
    xu = hasXu free

canonicalizeParsedTerm :: (ZG.Free, ZG.Text, ZG.Terminator) -> Either String T.Text
canonicalizeParsedTerm (free, ZG.Terms [term] _, terminator) = convertStructuredTerm term
canonicalizeParsedTerm x = Left $ "Unrecognized pattern for canonicalizeParsedTerm: " ++ show x

hasXu :: ZG.Free -> Bool
hasXu (ZG.UI x) = x == "xu"
hasXu (ZG.UIF x y) = (x == "xu") || hasXu y
hasXu (ZG.BUIF x y z) = hasXu z
hasXu (ZG.DOIF x y) = hasXu y
hasXu (ZG.BDOIF x y z) = hasXu z
hasXu (ZG.COIF x y) = hasXu y
hasXu (ZG.BCOIF x y z) = hasXu z
hasXu (ZG.COIs xs y) = any hasXu xs
hasXu (ZG.Vocative xs y z) = any hasXu xs
hasXu _ = False

convertText :: ZG.Text -> Either String T.Text
convertText text = canonicalizeParsedText (ZG.NF, text, ZG.NT)

convertBridi :: ZG.Text -> Either String T.Text
convertBridi text = canonicalizeParsedBridi (ZG.NF, text, ZG.NT)

convertTerm :: ZG.Text -> Either String T.Text
convertTerm term = canonicalizeParsedTerm (ZG.NF, ZG.Terms [term] ZG.NT, ZG.NT)
