{-# LANGUAGE TypeFamilies, 
    TypeSynonymInstances, FlexibleInstances, RecordWildCards #-}

module Compile (compileFile, CompileConfig (..)) where

import ProgName (progName)
import State
   (setBlockState, getBlockState, initBlockState, initState,
    newBlock, useBlock, setNextBlock, emitCode, emitCodeArg, emitCodeNoArg,
    compileName, compileConstant, reverseBlockMapBytecodes)
import Assemble (assemble)
import Monad (Compile (..), runCompileMonad)
import StackDepth (maxStackDepth)
import Types
   (Identifier, BlockID, BlockMap, CompileConfig (..), NameID, NameMap
   , ConstantID, ConstantMap, CompileState (..), BlockState (..), BlockVal (..))
import Scope (Scope (..), empty )
import Blip.Marshal as Blip (writePyc, PycFile (..), PyObject (..))
import Blip.Bytecode (Bytecode (..), BytecodeArg (..), Opcode (..), encode)
import Language.Python.Version3.Parser (parseModule)
import Language.Python.Common.AST as AST
   (ModuleSpan (..), Module (..), StatementSpan (..), Statement (..)
   , ExprSpan (..), Expr (..), Ident (..))
import Language.Python.Common (prettyText)
import System.FilePath ((<.>), takeBaseName)
import System.Directory (doesFileExist, getModificationTime)
import System.Time (ClockTime (..))
import System.IO (openFile, IOMode(..), Handle, hClose, hFileSize, hGetContents)
import Data.Word (Word32, Word16)
import Data.Traversable as Traversable (mapM)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.ByteString.Lazy as B (empty)
import Data.List (sort)
import Control.Monad (unless)
import Control.Exception (try)
import System.IO.Error (IOError, userError, ioError)

compiler :: Compilable a => a -> CompileState -> IO (CompileResult a)
compiler = runCompileMonad . compile

class Compilable a where
   type CompileResult a :: *
   compile :: a -> Compile (CompileResult a)

compileFile :: CompileConfig -> FilePath -> IO ()
compileFile config path = do
   r <- try $ do
      pyHandle <- openFile path ReadMode
      sizeInBytes <- hFileSize pyHandle
      fileContents <- hGetContents pyHandle
      modifiedTime <- getModificationTime path
      let modSeconds = case modifiedTime of TOD secs _picoSecs -> secs
      pyModule <- parseAndCheckErrors fileContents path
      pyc <- compileModule config (fromIntegral modSeconds) (fromIntegral sizeInBytes) pyModule
      let pycFilePath = takeBaseName path <.> ".pyc"
      pycHandle <- openFile pycFilePath WriteMode 
      writePyc pycHandle pyc
      hClose pycHandle
   -- XXX maybe we want more customised error messages for different kinds of
   -- IOErrors?
   case r of
      Left e -> putStrLn $ progName ++ ": " ++ show (e :: IOError)
      Right () -> return ()

parseAndCheckErrors :: String -> FilePath -> IO ModuleSpan
parseAndCheckErrors fileContents sourceName =
   case parseModule fileContents sourceName of
      -- Left e -> ioError $ userError $ show e
      Left e -> error $ "parse error: " ++ prettyText e
      Right (pyModule, _comments) -> return pyModule

compileModule :: CompileConfig -> Word32 -> Word32 -> ModuleSpan -> IO PycFile
compileModule config pyFileModifiedTime pyFileSizeBytes mod = do
   let state = initState config 
   obj <- compiler mod state
   return $ PycFile
      { magic = compileConfig_magic config 
      , modified_time = pyFileModifiedTime 
      , size = pyFileSizeBytes
      , object = obj }

instance Compilable a => Compilable [a] where
   type CompileResult [a] = [CompileResult a]
   compile = Traversable.mapM compile

instance Compilable a => Compilable (Maybe a) where
   type CompileResult (Maybe a) = Maybe (CompileResult a)
   compile = Traversable.mapM compile

instance Compilable ModuleSpan where
   type CompileResult ModuleSpan = PyObject
   compile (Module stmts) = compile $ Body stmts

-- body of module, function and class
newtype Body = Body [StatementSpan]

instance Compilable Body where
   type CompileResult Body = PyObject
   compile (Body stmts) = do
      setBlockState initBlockState
      Traversable.mapM compile stmts
      -- XXX should avoid returning None if a return statement preceeds it in the current block
      returnNone
      state <- getBlockState id
      -- The bytecodes are in reverse order after compiling a block
      let blockMapRev = state_blockMap state
          -- Put the bytecodes in the correct order
          blockMap = reverseBlockMapBytecodes blockMapRev 
          code = assemble blockMap
          stackDepth = maxStackDepth 0 blockMap
      makeObject (state_names state) (state_constants state)
                 code stackDepth

instance Compilable StatementSpan where
   type CompileResult StatementSpan = ()
   -- XXX fix multiple assignment
   compile (Assign [Var ident _] e _) = do
      compile e
      nameID <- compileName $ ident_string ident
      emitCodeArg STORE_NAME nameID
   -- XXX should check if return statement is inside a function body
   compile (Return { return_expr = Nothing }) = returnNone
   compile (Return { return_expr = Just expr }) = 
      compile expr >> emitCodeNoArg RETURN_VALUE
   compile (Pass {}) = return ()
   -- Don't emit code for pure expressions, as statements they have no
   -- observable effect.
   compile (StmtExpr { stmt_expr = expr }) = do
      unless (isPureExpr expr) $ 
         compile expr >> emitCodeNoArg POP_TOP
   compile s = error ("Unsupported statement " ++ show s)

instance Compilable ExprSpan where
   type CompileResult ExprSpan = ()
   compile (AST.Int {..}) =
      compileConstant $ Blip.Int $ fromIntegral int_value
   compile (AST.None {}) = compileConstant Blip.None
   compile (Paren { paren_expr = expr }) = compile expr

-- True if evaluating an expression has no observable side effect
-- Raising an exception is a side-effect, so variables are not pure.
isPureExpr :: ExprSpan -> Bool
isPureExpr (AST.Int {}) = True
isPureExpr (AST.LongInt {}) = True
isPureExpr (AST.Float {}) = True
isPureExpr (AST.Imaginary {}) = True
isPureExpr (AST.Bool {}) = True
isPureExpr (AST.None {}) = True
isPureExpr (AST.ByteStrings {}) = True
isPureExpr (AST.Strings {}) = True
isPureExpr (AST.UnicodeStrings {}) = True
isPureExpr (AST.Tuple { tuple_exprs = exprs }) = all isPureExpr exprs 
isPureExpr (AST.List { list_exprs = exprs }) = all isPureExpr exprs 
isPureExpr (AST.Set { set_exprs = exprs }) = all isPureExpr exprs 
isPureExpr (AST.Paren { paren_expr = expr }) = isPureExpr expr
isPureExpr (AST.Dictionary { dict_mappings = mappings }) =
   all (\(e1, e2) -> isPureExpr e1 && isPureExpr e2) mappings
-- XXX what about Lambda?
isPureExpr other = False

makeObject :: NameMap -> ConstantMap -> [Bytecode] -> Word32 -> Compile PyObject
makeObject names constants code maxStackDepth = do
   if maxStackDepth > maxBound
      -- XXX make a better error message
      then error "Maximum stack depth exceeded"
      else do
         let obj = Code
                   { argcount = 0
                   , kwonlyargcount = 0
                   , nlocals = 0
                   , stacksize = maxStackDepth 
                   , flags = 0
                   , code = String $ encode code
                   , consts = makeConstants constants
                   , names = makeNames names
                   , varnames = Blip.Tuple []
                   , freevars = Blip.Tuple [] 
                   , cellvars = Blip.Tuple []
                   , filename = Unicode "somefile"
                   , name = Unicode "somename"
                   , firstlineno = 0
                   , lnotab = String B.empty
                   }
         return obj

makeConstants :: ConstantMap -> PyObject
makeConstants constantMap = mapToObject constantMap id

makeNames :: NameMap -> PyObject
makeNames nameMap = mapToObject nameMap Unicode

mapToObject :: Map.Map key Word16 -> (key -> PyObject) -> PyObject
mapToObject theMap keyToObj = 
   Blip.Tuple $ theObjects
   where
   theObjects = map snd $ sort $ 
      [(identity, keyToObj key) | (key, identity) <- Map.toList theMap]

returnNone :: Compile ()
returnNone = compileConstant Blip.None >> emitCodeNoArg RETURN_VALUE
