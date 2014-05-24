-- | This module contains the code for Incremental checking, which finds the 
--   part of a target file (the subset of the @[CoreBind]@ that have been 
--   modified since it was last checked, as determined by a diff against
--   a saved version of the file. 

{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE FlexibleInstances         #-}

module Language.Haskell.Liquid.DiffCheck (
  
   -- * Changed binders + Unchanged Errors
     DiffCheck (..)
   
   -- * Use previously saved info to generate DiffCheck target 
   , slice

   -- * Use target binders to generate DiffCheck target 
   , thin
   
   -- * Save current information for next time 
   , saveResult

   ) 
   where

import            Control.Applicative          ((<$>), (<*>))
import            Data.Aeson                   
import qualified  Data.Text as T
import            Data.Algorithm.Diff
import            Data.Monoid                   (mempty)
import            Data.Maybe                    (listToMaybe, mapMaybe, fromMaybe)
import qualified  Data.IntervalMap.FingerTree as IM 
import            CoreSyn                      
import            Name
import            SrcLoc  
import            Var 
import qualified  Data.HashSet                  as S    
import qualified  Data.HashMap.Strict           as M    
import qualified  Data.List                     as L
import            Data.Function                   (on)
import            System.Directory                (copyFile, doesFileExist)
import            Language.Fixpoint.Types         (FixResult (..))
import            Language.Fixpoint.Files
import            Language.Haskell.Liquid.Types   (errSpan, Error (..))
import            Language.Haskell.Liquid.GhcInterface
import            Language.Haskell.Liquid.GhcMisc
import            Text.Parsec.Pos                  (sourceName, sourceLine, sourceColumn, SourcePos, newPos)
import            Control.Monad                   (forM, forM_)

import qualified  Data.ByteString.Lazy               as B

-------------------------------------------------------------------------
-- Data Types -----------------------------------------------------------
-------------------------------------------------------------------------

-- | Main type of value returned for diff-check.
data DiffCheck = DC { newBinds  :: [CoreBind] 
                    , oldResult :: FixResult Error
                    }

data Def  = D { binder :: Var -- ^ name of binder
              , start  :: Int -- ^ line at which binder definition starts
              , end    :: Int -- ^ line at which binder definition ends
              } 
            deriving (Eq, Ord)

-- | Variable dependencies "call-graph"
type Deps = M.HashMap Var (S.HashSet Var)

-- | Map from saved-line-num ---> current-line-num
type LMap = IM.IntervalMap Int Int


instance Show Def where 
  show (D i j x) = showPpr x ++ " start: " ++ show i ++ " end: " ++ show j



-- | `slice` returns a subset of the @[CoreBind]@ of the input `target` 
--    file which correspond to top-level binders whose code has changed 
--    and their transitive dependencies.
-------------------------------------------------------------------------
slice :: FilePath -> [CoreBind] -> IO (Maybe DiffCheck)
-------------------------------------------------------------------------
slice target cbs = ifM (doesFileExist saved) (Just <$> dc) (return Nothing)
  where 
    saved        = extFileName Saved target
    dc           = sliceSaved target saved cbs 

sliceSaved :: FilePath -> FilePath -> [CoreBind] -> IO DiffCheck
sliceSaved target saved cbs 
  = do (is, lm) <- lineDiff target saved
       res      <- loadResult target
       return    $ sliceSaved' is lm (DC cbs res) 

sliceSaved'          :: [Int] -> LMap -> DiffCheck -> DiffCheck
sliceSaved' is lm dc = DC cbs' res'
  where
    cbs'             = thin cbs $ diffVars is dfs
    res'             = adjustResult lm chDfs res
    dfs              = coreDefs cbs
    chDfs            = coreDefs cbs'
    DC cbs res       = dc

-- | @thin@ returns a subset of the @[CoreBind]@ given which correspond
--   to those binders that depend on any of the @Var@s provided.
-------------------------------------------------------------------------
thin :: [CoreBind] -> [Var] -> [CoreBind] 
-------------------------------------------------------------------------
thin cbs xs = filterBinds cbs ys 
  where
    ys      = dependentVars (coreDeps cbs) $ S.fromList xs


-------------------------------------------------------------------------
filterBinds        :: [CoreBind] -> S.HashSet Var -> [CoreBind]
-------------------------------------------------------------------------
filterBinds cbs ys = filter f cbs
  where 
    f (NonRec x _) = x `S.member` ys 
    f (Rec xes)    = any (`S.member` ys) $ fst <$> xes 

-------------------------------------------------------------------------
coreDefs     :: [CoreBind] -> [Def]
-------------------------------------------------------------------------
coreDefs cbs = L.sort [D x l l' | b <- cbs, let (l, l') = coreDef b, x <- bindersOf b]
coreDef b    = meetSpans b eSp vSp 
  where 
    eSp      = lineSpan b $ catSpans b $ bindSpans b 
    vSp      = lineSpan b $ catSpans b $ getSrcSpan <$> bindersOf b

-- | `meetSpans` cuts off the start-line to be no less than the line at which 
--   the binder is defined. Without this, i.e. if we ONLY use the ticks and
--   spans appearing inside the definition of the binder (i.e. just `eSp`) 
--   then the generated span can be WAY before the actual definition binder,
--   possibly due to GHC INLINE pragmas or dictionaries OR ...
--   for an example: see the "INCCHECK: Def" generated by 
--      liquid -d benchmarks/bytestring-0.9.2.1/Data/ByteString.hs
--   where `spanEnd` is a single line function around 1092 but where
--   the generated span starts mysteriously at 222 where Data.List is imported. 

meetSpans b Nothing       _       
  = error $ "INCCHECK: cannot find span for top-level binders: " 
          ++ showPpr (bindersOf b)
          ++ "\nRun without --diffcheck option\n"

meetSpans b (Just (l,l')) Nothing 
  = (l, l')
meetSpans b (Just (l,l')) (Just (m,_)) 
  = (max l m, l')

lineSpan _ (RealSrcSpan sp) = Just (srcSpanStartLine sp, srcSpanEndLine sp)
lineSpan b _                = Nothing -- error $ "INCCHECK: lineSpan unexpected dummy span in lineSpan" ++ showPpr (bindersOf b)

catSpans b []             = error $ "INCCHECK: catSpans: no spans found for " ++ showPpr b
catSpans b xs             = foldr1 combineSrcSpans xs

bindSpans (NonRec x e)    = getSrcSpan x : exprSpans e
bindSpans (Rec    xes)    = map getSrcSpan xs ++ concatMap exprSpans es
  where 
    (xs, es)              = unzip xes
exprSpans (Tick t _)      = [tickSrcSpan t]
exprSpans (Var x)         = [getSrcSpan x]
exprSpans (Lam x e)       = getSrcSpan x : exprSpans e 
exprSpans (App e a)       = exprSpans e ++ exprSpans a 
exprSpans (Let b e)       = bindSpans b ++ exprSpans e
exprSpans (Cast e _)      = exprSpans e
exprSpans (Case e x _ cs) = getSrcSpan x : exprSpans e ++ concatMap altSpans cs 
exprSpans e               = [] 

altSpans (_, xs, e)       = map getSrcSpan xs ++ exprSpans e

-------------------------------------------------------------------------
coreDeps  :: [CoreBind] -> Deps
-------------------------------------------------------------------------
coreDeps  = M.fromList . concatMap bindDep 

bindDep b = [(x, ys) | x <- bindersOf b]
  where 
    ys    = S.fromList $ freeVars S.empty b

-------------------------------------------------------------------------
dependentVars :: Deps -> S.HashSet Var -> S.HashSet Var
-------------------------------------------------------------------------
dependentVars d    = {- tracePpr "INCCHECK: tx changed vars" $ -} 
                     go S.empty {- tracePpr "INCCHECK: seed changed vars" -} 
  where 
    pre            = S.unions . fmap deps . S.toList
    deps x         = M.lookupDefault S.empty x d
    go seen new 
      | S.null new = seen
      | otherwise  = let seen' = S.union seen new
                         new'  = pre new `S.difference` seen'
                     in go seen' new'

-------------------------------------------------------------------------
diffVars :: [Int] -> [Def] -> [Var]
-------------------------------------------------------------------------
diffVars lines defs  = -- tracePpr ("INCCHECK: diffVars lines = " ++ show lines ++ " defs= " ++ show defs) $ 
                       go (L.sort lines) (L.sort defs)
  where 
    go _      []     = []
    go []     _      = []
    go (i:is) (d:ds) 
      | i < start d  = go is (d:ds)
      | i > end d    = go (i:is) ds
      | otherwise    = binder d : go (i:is) ds 

-------------------------------------------------------------------------
-- Diff Interface -------------------------------------------------------
-------------------------------------------------------------------------


-- | `lineDiff src dst` compares the contents of `src` with `dst` 
--   and returns the lines of `src` that are different. 
-------------------------------------------------------------------------
lineDiff :: FilePath -> FilePath -> IO ([Int], LMap)
-------------------------------------------------------------------------
lineDiff src dst 
  = do s1      <- getLines src 
       s2      <- getLines dst
       let ns   = diffLines 1 $ getGroupedDiff s1 s2
       -- putStrLn $ "INCCHECK: diff lines = " ++ show ns
       return (ns, undefined)

diffLines _ []              = []
diffLines n (Both ls _ : d) = diffLines n' d                         where n' = n + length ls
diffLines n (First ls : d)  = [n .. (n' - 1)] ++ diffLines n' d      where n' = n + length ls
diffLines n (Second _ : d)  = diffLines n d 

getLines = fmap lines . readFile

rawDiff cbs = DC cbs mempty

-- | @save@ creates an .saved version of the @target@ file, which will be 
--    used to find what has changed the /next time/ @target@ is checked.
-------------------------------------------------------------------------
saveResult :: FilePath -> FixResult Error -> IO ()
-------------------------------------------------------------------------
saveResult target res 
  = do copyFile target saveF
       B.writeFile errF $ encode res 
    where
       saveF = extFileName Saved  target
       errF  = extFileName Errors target

-------------------------------------------------------------------------
loadResult   :: FilePath -> IO (FixResult Error) 
-------------------------------------------------------------------------
loadResult f = ifM (doesFileExist errF) res (return mempty)  
  where
    errF     = extFileName Errors f
    res      = (fromMaybe mempty . decode) <$> B.readFile errF

-------------------------------------------------------------------------
adjustResult :: LMap -> [Def] -> FixResult Error -> FixResult Error
-------------------------------------------------------------------------
adjustResult lm cd (Unsafe es)   = Unsafe (adjustErrors lm cd es)
adjustResult lm cd (Crash es z)  = Crash  (adjustErrors lm cd es) z
adjustResult _  _  r             = r

adjustErrors lm cd               =  unCheckedDefs cd . mapMaybe (adjustError lm) 

adjustError lm (ErrSaved sp msg) = (`ErrSaved` msg) <$> adjustSpan lm sp 
adjustError lm e                 = Just e 

adjustSpan lm (RealSrcSpan rsp)  = RealSrcSpan <$> adjustReal lm rsp 
adjustSpan lm sp                 = Just sp 
adjustReal lm rsp
  | Just δ <- getShift l1 lm     = Just $ realSrcSpan f (l1 + δ) c1 (l2 + δ) c2
  | otherwise                    = Nothing
  where
    (f, l1, c1, l2, c2)          = unpackRealSrcSpan rsp 
  
unCheckedDefs cd                 = filter . not . isCheckedError (checkedMap cd)

   
isCheckedError cm e
  | RealSrcSpan sp <- errSpan e  = isCheckedSpan sp
  | otherwise                    = False
  where
    isCheckedSpan                = not . null . (`IM.search` cm) . srcSpanStartLine  

-- | @getShift lm old@ returns @Just δ@ if the line number @old@ shifts by @δ@
-- in the diff and returns @Nothing@ otherwise.
getShift     :: Int -> LMap -> Maybe Int
getShift old = fmap snd . listToMaybe . IM.search old

-- | @setShift (lo, hi) δ lm@ updates the interval map @lm@ appropriately
setShift :: (Int, Int) -> Int -> LMap -> LMap
setShift (l1, l2) δ = IM.insert (IM.Interval l1 l2) δ

checkedMap :: [Def] -> IM.IntervalMap Int ()
checkedMap = undefined
 

ifM b x y    = b >>= \z -> if z then x else y

-------------------------------------------------------------------------
-- | Aeson instances ----------------------------------------------------
-------------------------------------------------------------------------

instance ToJSON SourcePos where
  toJSON p = object [   "sourceName"   .= f
                      , "sourceLine"   .= l
                      , "sourceColumn" .= c
                      ]
             where
               f    = sourceName   p
               l    = sourceLine   p
               c    = sourceColumn p

instance FromJSON SourcePos where
  parseJSON (Object v) = newPos <$> v .: "sourceName"   
                                <*> v .: "sourceLine"   
                                <*> v .: "sourceColumn"  
  parseJSON _            = mempty




instance ToJSON (FixResult Error)
instance FromJSON (FixResult Error)

-- Move to Fixpoint
-- instance ToJSON   Symbol  
-- instance FromJSON Symbol  
-- instance ToJSON   Subst 
-- instance FromJSON Subst
-- instance ToJSON   Sort
-- instance FromJSON Sort
-- instance ToJSON   SymConst 
-- instance FromJSON SymConst
-- instance ToJSON   Constant 
-- instance FromJSON Constant
-- instance ToJSON   Bop  
-- instance FromJSON Bop 
-- instance ToJSON   Brel  
-- instance FromJSON Brel
-- instance ToJSON   LocSymbol 
-- instance FromJSON LocSymbol 
-- instance ToJSON   FTycon 
-- instance FromJSON FTycon 
-- instance ToJSON   Expr 
-- instance FromJSON Expr 
-- instance ToJSON   Pred 
-- instance FromJSON Pred 
-- instance ToJSON   Refa 
-- instance FromJSON Refa 
-- instance ToJSON   Reft
-- instance FromJSON Reft
-- 
-- -- Move to Types
-- instance ToJSON   Predicate 
-- instance FromJSON Predicate 
-- instance ToJSON   LParseError 
-- instance FromJSON LParseError 
-- instance ToJSON   Oblig 
-- instance FromJSON Oblig 
-- instance ToJSON   Stratum
-- instance FromJSON Stratum
-- instance ToJSON   RReft
-- instance FromJSON RReft
-- instance ToJSON   UsedPVar
-- instance FromJSON UsedPVar
-- instance ToJSON   EMsg 
-- instance FromJSON EMsg

