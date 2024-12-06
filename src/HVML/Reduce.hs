-- //./Type.hs//

module HVML.Reduce where

import Control.Monad (when, forM, forM_)
import Data.Word
import HVML.Collapse
import HVML.Extract
import HVML.Inject
import HVML.Show
import HVML.Type
import System.Exit
import qualified Data.Map.Strict as MS

reduceAt :: Bool -> ReduceAt
reduceAt debug book tid host = do 
  term <- got host
  let tag = termTag term
  let lab = termLab term
  let loc = termLoc term
  when debug $ do
    root <- doExtractCoreAt (\ _ _ -> got) book 0
    core <- doExtractCoreAt (\ _ _ -> got) book host
    putStrLn $ "reduce: " ++ termToString term
    -- putStrLn $ "---------------- CORE: "
    -- putStrLn $ coreToString core
    putStrLn $ "---------------- ROOT: "
    putStrLn $ coreToString (doLiftDups root)
  case tagT tag of
    LET -> do
      case modeT lab of
        LAZY -> do
          val <- got (loc + 0)
          cont host (reduceLet 0 term val)
        STRI -> do
          val <- reduceAt debug book tid (loc + 0)
          cont host (reduceLet 0 term val)
        PARA -> do
          error "TODO"
    APP -> do
      fun <- reduceAt debug book tid (loc + 0)
      case tagT (termTag fun) of
        ERA -> cont host (reduceAppEra 0 term fun)
        LAM -> cont host (reduceAppLam 0 term fun)
        SUP -> cont host (reduceAppSup 0 term fun)
        CTR -> cont host (reduceAppCtr 0 term fun)
        W32 -> cont host (reduceAppW32 0 term fun)
        CHR -> cont host (reduceAppW32 0 term fun)
        _   -> set (loc + 0) fun >> return term
    MAT -> do
      val <- reduceAt debug book tid (loc + 0)
      case tagT (termTag val) of
        ERA -> cont host (reduceMatEra 0 term val)
        LAM -> cont host (reduceMatLam 0 term val)
        SUP -> cont host (reduceMatSup 0 term val)
        CTR -> cont host (reduceMatCtr 0 term val)
        W32 -> cont host (reduceMatW32 0 term val)
        CHR -> cont host (reduceMatW32 0 term val)
        _   -> set (loc + 0) val >> return term
    OPX -> do
      val <- reduceAt debug book tid (loc + 0)
      case tagT (termTag val) of
        ERA -> cont host (reduceOpxEra 0 term val)
        LAM -> cont host (reduceOpxLam 0 term val)
        SUP -> cont host (reduceOpxSup 0 term val)
        CTR -> cont host (reduceOpxCtr 0 term val)
        W32 -> cont host (reduceOpxW32 0 term val)
        CHR -> cont host (reduceOpxW32 0 term val)
        _   -> set (loc + 0) val >> return term
    OPY -> do
      val <- reduceAt debug book tid (loc + 1)
      case tagT (termTag val) of
        ERA -> cont host (reduceOpyEra 0 term val)
        LAM -> cont host (reduceOpyLam 0 term val)
        SUP -> cont host (reduceOpySup 0 term val)
        CTR -> cont host (reduceOpyCtr 0 term val)
        W32 -> cont host (reduceOpyW32 0 term val)
        CHR -> cont host (reduceOpyW32 0 term val)
        _   -> set (loc + 1) val >> return term
    DP0 -> do
      sb0 <- got (loc + 0)
      if termGetBit sb0 == 0
        then do
          val <- reduceAt debug book tid (loc + 0)
          case tagT (termTag val) of
            ERA -> cont host (reduceDupEra 0 term val)
            LAM -> cont host (reduceDupLam 0 term val)
            SUP -> cont host (reduceDupSup 0 term val)
            CTR -> cont host (reduceDupCtr 0 term val)
            W32 -> cont host (reduceDupW32 0 term val)
            CHR -> cont host (reduceDupW32 0 term val)
            _   -> set (loc + 0) val >> return term
        else do
          set host (termRemBit sb0)
          reduceAt debug book tid host
    DP1 -> do
      sb1 <- got (loc + 1)
      if termGetBit sb1 == 0
        then do
          val <- reduceAt debug book tid (loc + 0)
          case tagT (termTag val) of
            ERA -> cont host (reduceDupEra 0 term val)
            LAM -> cont host (reduceDupLam 0 term val)
            SUP -> cont host (reduceDupSup 0 term val)
            CTR -> cont host (reduceDupCtr 0 term val)
            W32 -> cont host (reduceDupW32 0 term val)
            CHR -> cont host (reduceDupW32 0 term val)
            _   -> set (loc + 0) val >> return term
        else do
          set host (termRemBit sb1)
          reduceAt debug book tid host
    VAR -> do
      sub <- got (loc + 0)
      if termGetBit sub == 0
        then return term
        else do
          set host (termRemBit sub)
          reduceAt debug book tid host
    REF -> do
      reduceRefAt book tid host
      reduceAt debug book tid host
    otherwise -> do
      return term
  where
    cont host action = do
      ret <- action
      set host ret
      reduceAt debug book tid host

reduceRefAt :: Book -> TID -> Loc -> HVM Term
reduceRefAt book tid host = do
  term <- got host
  let lab = termLab term
  let loc = termLoc term
  let fid = u12v2X lab
  let ari = u12v2Y lab
  case fid of
    x | x == _DUP_F_ -> reduceRefAt_DupF book tid host loc ari
    x | x == _SUP_F_ -> reduceRefAt_SupF book tid host loc ari
    x | x == _LOG_F_ -> reduceRefAt_LogF book tid host loc ari
    oterwise -> case MS.lookup fid (idToFunc book) of
      Just ((copy, args), core) -> do
        incItr tid 1
        when (length args /= fromIntegral ari) $ do
          putStrLn $ "RUNTIME_ERROR: arity mismatch on call to '@" ++ mget (idToName book) fid ++ "'."
          exitFailure
        argTerms <- if ari == 0
          then return [] 
          else forM (zip [0..] args) $ \(i, (strict, _)) -> do
            term <- got (loc + i)
            if strict
              then reduceAt False book tid (loc + i)
              else return term
        doInjectCoreAt book core host $ zip (map snd args) argTerms
        -- TODO: I disabled Fast Copy Optimization on interpreted mode because I
        -- don't think it is relevant here. We use it for speed, to trigger the
        -- hot paths on compiled functions, which don't happen when interpreted.
        -- I think leaving it out is good because it ensures interpreted mode is
        -- always optimal (minimizing interactions). This also allows the dev to
        -- see how Fast Copy Mode affects the interaction count.
        -- let inject = doInjectCoreAt book core host $ zip (map snd args) argTerms
        -- Fast Copy Optimization
        -- if copy then do
          -- let supGet = \x (idx,sup) -> if tagT (termTag sup) == SUP then Just (idx,sup) else x
          -- let supGot = foldl' supGet Nothing $ zip [0..] argTerms
          -- case supGot of
            -- Just (idx,sup) -> do
              -- let isCopySafe = case MS.lookup fid (idToLabs book) of
                    -- Nothing   -> False
                    -- Just labs -> not $ MS.member (termLab sup) labs
              -- if isCopySafe then do
                -- term <- reduceRefSup term idx
                -- set host term
                -- return term
              -- else inject
            -- otherwise -> inject
        -- else inject
      Nothing -> do
        return term

-- Primitive: Dynamic Dup `@DUP(lab val λdp0λdp1(bod))`
reduceRefAt_DupF :: Book -> TID -> Loc -> Loc -> Word64 -> HVM Term  
reduceRefAt_DupF book tid host loc ari = do
  incItr tid 1
  when (ari /= 3) $ do
    putStrLn $ "RUNTIME_ERROR: arity mismatch on call to '@DUP'."
    exitFailure
  -- lab <- reduceAt False book tid (loc + 0)
  lab <- got (loc + 0)
  val <- got (loc + 1)
  bod <- got (loc + 2)
  dup <- allocNode 0 2
  case tagT (termTag lab) of
    W32 -> do
      when (termLoc lab >= 0x1000000) $ do
        error "RUNTIME_ERROR: dynamic DUP label too large"
      -- Create the DUP node with value and SUB
      set (dup + 0) val
      set (dup + 1) (termNew _SUB_ 0 0)
      -- Create first APP node for (APP bod DP0)
      app1 <- allocNode 0 2
      set (app1 + 0) bod
      set (app1 + 1) (termNew _DP0_ (termLoc lab) dup)
      -- Create second APP node for (APP (APP bod DP0) DP1)
      app2 <- allocNode 0 2
      set (app2 + 0) (termNew _APP_ 0 app1)
      set (app2 + 1) (termNew _DP1_ (termLoc lab) dup)
      let ret = termNew _APP_ 0 app2
      set host ret
      return ret
    _ -> do
      core <- doExtractCoreAt (\ _ _ -> got) book (loc + 0)
      putStrLn $ "RUNTIME_ERROR: dynamic DUP without numeric label: " ++ termToString lab
      putStrLn $ coreToString (doLiftDups core)
      exitFailure

-- Primitive: Dynamic Sup `@SUP(lab tm0 tm1)`
reduceRefAt_SupF :: Book -> TID -> Loc -> Loc -> Word64 -> HVM Term
reduceRefAt_SupF book tid host loc ari = do
  incItr tid 1
  when (ari /= 3) $ do
    putStrLn $ "RUNTIME_ERROR: arity mismatch on call to '@SUP'."
    exitFailure
  -- lab <- reduceAt False book tid (loc + 0)
  lab <- got (loc + 0)
  tm0 <- got (loc + 1)
  tm1 <- got (loc + 2)
  sup <- allocNode 0 2
  case tagT (termTag lab) of
    W32 -> do
      when (termLoc lab >= 0x1000000) $ do
        error "RUNTIME_ERROR: dynamic SUP label too large"
      let ret = termNew _SUP_ (termLoc lab) sup
      set (sup + 0) tm0
      set (sup + 1) tm1
      set host ret
      return ret
    _ -> error "RUNTIME_ERROR: dynamic SUP without numeric label."

-- Primitive: Logger `@LOG(msg)`
-- Will extract the term and log it. 
-- Returns 0.
reduceRefAt_LogF :: Book -> TID -> Loc -> Loc -> Word64 -> HVM Term
reduceRefAt_LogF book tid host loc ari = do
  incItr tid 1
  when (ari /= 1) $ do
    putStrLn $ "RUNTIME_ERROR: arity mismatch on call to '@LOG'."
    exitFailure
  msg <- doExtractCoreAt (\ _ _ -> got) book (loc + 0)
  putStrLn $ coreToString (doLiftDups msg)
  -- msgs <- doCollapseFlatAt (const got) book (loc + 0)
  -- forM_ msgs $ \msg -> do
    -- putStrLn $ coreToString msg
  let ret = termNew _W32_ 0 0
  set host ret
  return ret

reduceCAt :: Bool -> ReduceAt
reduceCAt debug = \ book tid host -> do
  term <- got host
  whnf <- reduceC tid term
  set host whnf
  return $ whnf

-- normalAtWith :: (Book -> Term -> HVM Term) -> Book -> Loc -> HVM Term
-- normalAtWith reduceAt book host = do
  -- term <- got host
  -- if termBit term == 1 then do
    -- return term
  -- else do
    -- whnf <- reduceAt book host
    -- set host $ termSetBit whnf
    -- let tag = termTag whnf
    -- let lab = termLab whnf
    -- let loc = termLoc whnf
    -- case tagT tag of
      -- APP -> do
        -- normalAtWith reduceAt book (loc + 0)
        -- normalAtWith reduceAt book (loc + 1)
        -- return whnf
      -- LAM -> do
        -- normalAtWith reduceAt book (loc + 1)
        -- return whnf
      -- SUP -> do
        -- normalAtWith reduceAt book (loc + 0)
        -- normalAtWith reduceAt book (loc + 1)
        -- return whnf
      -- DP0 -> do
        -- normalAtWith reduceAt book (loc + 0)
        -- return whnf
      -- DP1 -> do
        -- normalAtWith reduceAt book (loc + 0)
        -- return whnf
      -- CTR -> do
        -- let ari = u12v2Y lab
        -- let ars = (if ari == 0 then [] else [0 .. ari - 1]) :: [Word64]
        -- mapM_ (\i -> normalAtWith reduceAt book (loc + i)) ars
        -- return whnf
      -- MAT -> do
        -- let ari = lab
        -- let ars = [0 .. ari] :: [Word64]
        -- mapM_ (\i -> normalAtWith reduceAt book (loc + i)) ars
        -- return whnf
      -- _ -> do
        -- return whnf

-- normalAt :: Book -> Loc -> HVM Term
-- normalAt = normalAtWith (reduceAt False)

-- normalCAt :: Book -> Loc -> HVM Term
-- normalCAt = normalAtWith (reduceCAt False)
