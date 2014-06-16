{- 
   Copyright (c) Microsoft Corporation
   All rights reserved. 

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}
{-# OPTIONS_GHC -fwarn-unused-binds #-}
{-# OPTIONS_GHC -fwarn-unused-imports #-}

module CgLUT
  ( codeGenLUTExp
  , pprLUTStats
  , shouldLUT
  ) where


import Opts
import AstExpr
import {-# SOURCE #-} CgExpr
import CgMonad hiding (State)
import CgTypes
import SysTools
import Analysis.Range
import Analysis.UseDef

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe ( isJust, fromJust )
import Data.Word
import Language.C.Quote.C
import qualified Language.C.Syntax as C
import System.Directory(getTemporaryDirectory)
import System.IO (IOMode(..),
                  hClose,
                  hGetContents,
                  openFile,
                  openTempFile)
import Text.PrettyPrint.Mainland

import LUTAnalysis

--  import System.Exit ( exitFailure )

-- XXX TODO
--
-- These are bugs!
-- 
-- * When generating a LUT, we should only iterate over the values that are in a
-- variable's range, i.e., those that we know are used.
--
-- * We must know the range of any variable that is used as part of an array
-- index calculation in an expression if we want LUT the expression. Otherwise
-- we may access an array at an illegal index.

-- If we need more than 32 bits for the index, the LUT is going to be at least
-- 2^32 bytes, so 
lutIndexTypeByWidth :: Monad m => Int -> m C.Type
lutIndexTypeByWidth n
    | n <= 8    = return [cty|typename uint8|]
    | n <= 16   = return [cty|typename uint16|]
    | n <= 32   = return [cty|typename uint32|] 
    | otherwise 
    = fail "lutIndexTypeByWidth: need at most 32 bits for the LUT index"


-- We know that the index is at most 4 bytes and we can pack using
-- simple shifts, without involving the more expensive
-- bitArrRead/bitArrWrite library functions.

packIdx :: Map Name Range    -- Ranges
                  -> [VarTy] -- Variables
                  -> C.Exp   -- A C expression for the index variable
                  -> C.Type  -- The actual index type (typically unsigned int)
                  -> Cg ()
packIdx ranges vs tgt tgt_ty = go vs 0
  where go [] _ = return ()
        go ((v,ty):vs) pos
         | isArrTy ty 
         = do { w <- varBitWidth ranges v ty
              ; let mask = 2^w - 1
              ; (_,varexp) <- lookupVarEnv v
              ; appendStmt $ [cstm| $tgt |= (($ty:tgt_ty) (*$varexp)) & $int:mask << $int:pos; |]
              -- ; appendStmt $ [cstm| bitArrWrite((typename BitArrPtr) $varexp, $int:pos, $int:w, $tgt); |]
              ; go vs (pos+w) }
         | otherwise
         = do { w <- varBitWidth ranges v ty
              ; let mask = 2^w - 1
              ; (_,varexp) <- lookupVarEnv v
              ; appendStmt $ [cstm| $tgt |= (($ty:tgt_ty) $varexp) & $int:mask << $int:pos; |]
              -- ; appendStmt $ [cstm| bitArrWrite((typename BitArrPtr) & $varexp, $int:pos, $int:w, $tgt); |]
              ; go vs (pos+w) }

unpackIdx :: [VarTy] -- Variables
          -> C.Exp   -- A C expression representing the index
          -> C.Type  -- The index type (typically unsigned int)
          -> Cg ()
unpackIdx xs src src_ty = go xs 0
  where go [] _ = return ()
        go ((v,ty):vs) pos
         | TArr basety alen <- ty
         , let bytesizeof = tySizeOf_C ty
         = do { (_,varexp) <- lookupVarEnv v
              ; w <- tyBitWidth ty 

              ; let mask = 2^w - 1
              ; tmpname <- freshName "tmp"
              
              -- ORIGINAL, but wrong: ; appendStmt $ [cstm| * ($ty:src_ty *) $varexp = ($src >> $int:pos) & $int:mask; |]              

              ; appendDecl [cdecl| $ty:src_ty $id:(name tmpname) = ($src >> $int:pos) & $int:mask; |]
              ; appendStmt [cstm| memcpy((void *) $varexp, (void *) & ($id:(name tmpname)), $bytesizeof);|]

              ; go vs (pos+w) }
         | otherwise 
         = do { (_,varexp) <- lookupVarEnv v
              ; w <- tyBitWidth ty
              ; let mask = 2^w - 1  
              ; appendStmt $ [cstm| $varexp = ($src >> $int:pos) & $int:mask; |]
              -- ; appendStmt $ [cstm| bitArrRead($src,$int:pos,$int:w, (typename BitArrPtr) & $varexp); |] 
              ; go vs (pos+w) }



packByteAligned :: Map Name Range -- Ranges
               -> [VarTy]         -- Variables
               -> C.Exp           -- A C expression of type BitArrPtr
               -> Cg ()
packByteAligned ranges vs tgt = go vs 0
  where go [] _ = return ()
        go ((v,ty):vs) pos
         | isArrTy ty 
         = do { w <- varBitWidth ranges v ty
              ; (_,varexp) <- lookupVarEnv v
              ; appendStmt $ [cstm| bitArrWrite((typename BitArrPtr) $varexp, $int:pos, $int:w, $tgt); |]
              ; go vs (byte_align (pos+w)) } -- Align for next write!
         | otherwise
         = do { w <- varBitWidth ranges v ty
              ; (_,varexp) <- lookupVarEnv v
              ; appendStmt $ [cstm| bitArrWrite((typename BitArrPtr) & $varexp, $int:pos, $int:w, $tgt); |]
              ; go vs (byte_align (pos+w)) }  -- Align for next write!

byte_align n = ((n+7) `div` 8) * 8

unpackByteAligned :: [VarTy] -- Variables
                   -> C.Exp   -- A C expression of type BitArrPtr
                   -> Cg ()
unpackByteAligned xs src = go xs 0
  where go [] _ = return ()
        go ((v,ty):vs) pos
         | isArrTy ty 
         = do { (_,varexp) <- lookupVarEnv v
              ; w <- tyBitWidth ty
              ; appendStmt $ [cstm| memcpy((void *) $varexp, (void *) & $src[$int:(pos `div` 8)], $int:(byte_align w `div` 8));|]
              --; appendStmt $ [cstm| bitArrRead($src,$int:pos,$int:w, (typename BitArrPtr) $varexp); |] 
              ; go vs (byte_align (pos+w)) } -- Align for next read!
         | otherwise 
         = do { (_,varexp) <- lookupVarEnv v
              ; w <- tyBitWidth ty 
              ; appendStmt $ [cstm| blink_copy((void *) & $varexp, (void *) & $src[$int:(pos `div` 8)], $int:(byte_align w `div` 8));|]
              --; appendStmt $ [cstm| bitArrRead($src,$int:pos,$int:w, (typename BitArrPtr) & $varexp); |] 
              ; go vs (byte_align (pos+w)) } -- Align for next read!


csrcPathPosix :: DynFlags -> FilePath
csrcPathPosix dflags = head [ path | CSrcPathPosix path <- dflags]

csrcPathNative :: DynFlags -> FilePath
csrcPathNative dflags = head [ path | CSrcPathNative path <- dflags]


codeGenLUTExp :: DynFlags
              -> [(Name,Ty,Maybe (Exp Ty))]
              -> Map Name Range
              -> Exp Ty
              -> Cg C.Exp
codeGenLUTExp dflags locals_ ranges e 
  = case shouldLUT dflags locals ranges e of
      Left err -> 
        do { verbose dflags $ text "Asked to LUT un-LUTtable expression:" <+> string err </> nest 4 (ppr e)
           ; codeGenExp dflags e }
      Right True  -> lutIt
      Right False -> 
        do { verbose dflags $ text "Asked to LUT an expression we wouldn't normally LUT:" </> nest 4 (ppr e)
           ; lutStats <- calcLUTStats locals ranges e
           ; if lutTableSize lutStats >= aBSOLUTE_MAX_LUT_SIZE
             then do { verbose dflags $ text "LUT way too big!" </> fromJust (pprLUTStats dflags locals ranges e)
                     ; codeGenExp dflags e }
             else lutIt }
  where
    -- TODO: Document why this not the standard size but something much bigger? (Reason: alignment)
    aBSOLUTE_MAX_LUT_SIZE :: Integer
    aBSOLUTE_MAX_LUT_SIZE = 1024*1024

    locals :: [VarTy]
    -- TODO: local initializers are ignored?? Potential bug
    locals = [(v,ty) | (v,ty,_) <- locals_]

    lutIt :: Cg C.Exp
    lutIt = do
        (inVars, outVars, allVars) <- inOutVars locals ranges e

        verbose dflags $ text "Creating LUT for expression:" </> nest 4 (ppr e) </> 
                            nest 4 (text "Variable ranges:" </> pprRanges ranges) </> fromJust (pprLUTStats dflags locals ranges e)

        let resultInOutVars 
             | Just v <- expResultVar e
             , v `elem` map fst outVars = Just v
             | otherwise = Nothing

        clut <- genLUT dflags ranges inVars (outVars,resultInOutVars) allVars locals e
        genLUTLookup ranges inVars (outVars,resultInOutVars) clut (info e)

-- | Generate a LUT for a function. The LUT maps the values of variables used by
-- the function---its input variables---to the values of variables modified
-- imperatively by the function---its output variables---as well as the
-- function's result. If the result happens to be one of the imperatively
-- modified variables, storing it in the LUT would be redundant, so we don't. We
-- create the LUT by generating code for the expression we're LUTting, adding a
-- bit of C code to print out the value of the LUT entry we want to construct,
-- running the code, and then parsing its output and create a big C static array
-- with the values.
genLUT :: DynFlags -- ^ Flags
       -> Map Name Range
       -> [VarTy]              -- ^ Input variables
       -> ([VarTy],Maybe Name) -- ^ Output variables + result if not in outvars
       -> [VarTy]  -- ^ All used variables
       -> [VarTy]  -- ^ Local variables
       -> Exp Ty   -- ^ Expression to LUT
       -> Cg C.Exp -- ^ Returns true if the result is in out vars
genLUT dflags ranges inVars (outVars, res_in_outvars) allVars locals e = do
    inBitWidth <- varsBitWidth ranges inVars    
    cinBitType <- lutIndexTypeByWidth inBitWidth
                            
    -- 'clut' is the C variable that will hold the LUT.
    clut <- genSym "clut"

    -- 'cidx' is the C variable that we use to index into the LUT.
    cidx <- genSym "idx"

    
    (defs, (decls, stms, outBitWidth))
        <- collectDefinitions $ 
           inNewBlock $ 
           -- Just use identity code generation environment
           extendVarEnv [(v, (ty, [cexp|$id:(name v)|])) | (v,ty) <- allVars] $
           -- Generate local declarations for all input and output variables
           do { genLocalVarInits dflags allVars
              ; unpackIdx inVars [cexp|$id:cidx |] [cty|unsigned int|]
              ; mapM_ (\(v,_) -> ensureInRange v) inVars
              ; ce <- codeGenExp dflags e
              ; (outBitWidth, outVarsWithRes, result_env) <- 
                  if (isJust res_in_outvars || info e == TUnit) then
                    do { ow <- varsBitWidth_ByteAlign outVars
                         -- clut declaration and initialization to zeros
                       ; g <- codeGenArrVal clut (TArr (Literal ow) TBit) [VBit False]
                       ; appendDecl g
                       ; return (ow,outVars, []) }
                  else 
                    do { resval <- freshName "res";
                       ; codeGenDeclGroup (name resval) (info e) >>= appendDecl
                       ; let outVarsWithRes = outVars++[(resval,info e)]
                       ; ow <- varsBitWidth_ByteAlign outVarsWithRes
                         -- clut declaration and initialization to zeros
                       ; g <- codeGenArrVal clut (TArr (Literal ow) TBit) [VBit False]

                       ; appendDecl g 
                       ; assignByVal (info e) (info e) 
                                [cexp|$id:(name resval)|] ce
                       ; reswidth <- tyBitWidth (info e) 
                       ; let renv = 
                              [(resval,(info e, [cexp|$id:(name resval)|]))]
                       ; return (ow, outVarsWithRes, renv) }
              ; extendVarEnv result_env $ 
                packByteAligned ranges outVarsWithRes [cexp| $id:clut |]
              ; return outBitWidth
              }

    -- make a 2-byte aligned entry.
    let lutEntryByteLen = ((((outBitWidth + 7) `div` 8) + 1) `div` 2) * 2


    tempDir        <- liftIO $ getTemporaryDirectory
    (tablePath, h) <- liftIO $ openTempFile tempDir "table.txt"
    liftIO $ hClose h

    let cdoc = text cPrelude </>
                        ppr [cunit|$esc:("#include <assert.h>")
                                   $esc:("#include <stdio.h>")
                                   $esc:("#include \"types.h\"")
                                   $esc:("#include \"wpl_alloc.h\"")
                                   $esc:("#include \"utils.h\"")
                                 
                                   $edecls:defs

                                   int main(int argc, char** argv)
                                   {
                                     FILE* f; int b;
                                     
                                     f = fopen($string:tablePath, "w");
                                     assert(f != NULL);
                                     for(unsigned int $id:cidx = 0; 
                                              $id:cidx < $int:((1::Word) `shiftL` inBitWidth); 
                                              ($id:cidx)++)
                                     {

                                       $decls:decls
                                       $stms:stms

                                       for (b = 0; b < $int:(lutEntryByteLen); b++) {
                                             fprintf(f,"%d ", $id:clut[b]);
                                             printf("%d ", $id:clut[b]);
                                       }
                                             fprintf(f,"\n");
                                             printf("\n");
                                     }

                                     assert(fclose(f) == 0);

                                   }
                                  |]

    -- Dump the C source code.
    dump dflags DumpLUT ("lut_" ++ clut ++ ".c") cdoc

    -- Compile and run the program. 
    -- Its output is the LUT entries, one entry per line.


    out  <- liftIO $ 
          compileAndRun (pretty 80 cdoc) "lutexec" 
                        (csrcPathPosix dflags) 
                        (csrcPathNative dflags)
                        []

    h     <- liftIO $ openFile tablePath ReadMode
    table <- liftIO $ hGetContents h

    let get_field x = [cinit| $int:((read x) :: Int)|]
        get_entry x = [cinit| { $inits:(map get_field (words x)) } |]
        entries     = map get_entry (lines table)
        idxLen = (1::Word) `shiftL` inBitWidth
        lutbasety = namedCType $ "calign unsigned char"
        clutDecl = [cdecl| $ty:lutbasety $id:clut[$int:idxLen][$int:lutEntryByteLen] = { $inits:entries } ;|]

    -- Dump the static declaration.
    dump dflags DumpLUT ("table_" ++ clut ++ ".c") (ppr clutDecl)

    appendTopDecls [clutDecl]

    return ([cexp|$id:clut|])
  where
    -- Ensure that the given variable is in range
    ensureInRange :: Name -> Cg ()
    ensureInRange v 
     | Just (Range l h) <- Map.lookup v ranges  
     = do (_, ce) <- lookupVarEnv v
          appendStmt [cstm|if ($ce < $int:l || $ce > $int:h) { $ce = $int:l; }|]
     | otherwise = return ()

genLUTLookup :: Map Name Range
             -> [VarTy]                 -- ^ Input variables
             -> ([VarTy],Maybe Name)    -- ^ Output variables incl. possibly a 
                                        --   separate result variable!
             -> C.Exp                   -- ^ LUT table
             -> Ty                      -- ^ Expression type 
             -> Cg C.Exp
genLUTLookup ranges inVars (outVars,res_in_outvars) clut ety = do
    idx <- genSym "idx"
    appendDecl [cdecl| unsigned int $id:idx = 0; |]

    packIdx ranges inVars [cexp|$id:idx|] [cty|unsigned int|]

    case res_in_outvars of
      Just v -> 
        do { unpackByteAligned outVars 
                 [cexp| (typename BitArrPtr) $clut[$id:idx]|]
           ; (_,vcexp) <- lookupVarEnv v
           ; return vcexp }
      Nothing
        | ety == TUnit
        -> do { unpackByteAligned outVars [cexp| (typename BitArrPtr) $clut[$id:idx]|]
              ; return [cexp|UNIT |] }
        | otherwise
        -> do { res <- freshName "resx" 
              ; codeGenDeclGroup (name res) ety >>= appendDecl
              ; extendVarEnv [(res,(ety,[cexp|$id:(name res)|]))] $
                unpackByteAligned (outVars ++ [(res,ety)]) [cexp| (typename BitArrPtr) $clut[$id:idx]|]
              ; return $ [cexp| $id:(name res) |] }

cPrelude :: String
cPrelude = unlines ["#include <stdio.h>"
                   ,"#include <stdlib.h>"
                   ,"#include <string.h>"
                   ,"#include <math.h>"

{-
                   ,"#include <xmmintrin.h>"
                   ,"#include <emmintrin.h>"

                   ,"#include \"sse.h\""
                   ,"#include \"driver.h\""
                   ,"#include \"lut_wrapper.h\""
                   ,"#include \"externals.h\""
                   ,"#include \"fft.h\""
                   ,"#include \"soratypes.h\""
                   ,"#include \"intalg.h\""
-}
                   ,"#define FALSE 0"
                   ,"#define TRUE 1"
                   ,"#define UNIT 0"]

genLocalVarInits :: DynFlags -> [VarTy] -> Cg ()
genLocalVarInits dflags vs
  = do { ds <- mapM (\(v,ty) -> codeGenDeclGroup (name v) ty) vs
       ; appendDecls ds }

