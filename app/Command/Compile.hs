{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Command.Compile (command) where

import           Control.Concurrent
import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.Aeson as A
import           Data.Bool (bool)
import qualified Data.ByteString.Lazy.UTF8 as LBU8
import           Data.IORef
import           Data.List (intercalate, union)
import qualified Data.Map as M
import           Data.Maybe (fromJust, isNothing, catMaybes)
import           Data.Monoid ((<>))
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Traversable (for)
import qualified Language.PureScript as P
import           Language.PureScript.Errors.JSON
import           Language.PureScript.Make
import           Language.PureScript.Make.BuildPlan (Prebuilt)
import qualified Options.Applicative as Opts
import qualified System.Console.ANSI as ANSI
import           System.Exit (exitSuccess, exitFailure)
import           System.Directory (getCurrentDirectory)
import           System.FilePath.Glob (glob)
import           System.IO (hPutStr, hPutStrLn, stderr)
import           System.IO.UTF8 (readUTF8FileT)
import           System.FSNotify

data PSCMakeOptions = PSCMakeOptions
  { pscmInput        :: [FilePath]
  , pscmOutputDir    :: FilePath
  , pscmOpts         :: P.Options
  , pscmUsePrefix    :: Bool
  , pscmJSONErrors   :: Bool
  , pscmWatch        :: Bool
  , pscmWarnings     :: Bool
  }

-- | Argumnets: verbose, hide warnings, use JSON, warnings, errors
printWarningsAndErrors :: Bool -> Bool -> Bool -> P.MultipleErrors -> Either P.MultipleErrors a -> IO ([P.ModuleName], Maybe a)
printWarningsAndErrors verbose hide False warnings errors = do
  pwd <- getCurrentDirectory
  cc <- bool Nothing (Just P.defaultCodeColor) <$> ANSI.hSupportsANSI stderr
  let ppeOpts = P.defaultPPEOptions { P.ppeCodeColor = cc, P.ppeFull = verbose, P.ppeRelativeDirectory = pwd }
  when (P.nonEmpty warnings && not hide) $
    hPutStrLn stderr (P.prettyPrintMultipleWarnings ppeOpts warnings)
  case errors of
    Left errs -> do
      hPutStrLn stderr (P.prettyPrintMultipleErrors ppeOpts errs)
      return (catMaybes $ map P.errorModule $ P.runMultipleErrors errs, Nothing)
    Right a -> return $ ([], Just a)
printWarningsAndErrors verbose _ True warnings errors = do
  hPutStrLn stderr . LBU8.toString . A.encode $
    JSONResult (toJSONErrors verbose P.Warning warnings)
               (either (toJSONErrors verbose P.Error) (const []) errors)
  return $ ([], Nothing)
  return $ either ((,Nothing) . catMaybes . map P.errorModule . P.runMultipleErrors) (([],) . Just) errors

compile :: PSCMakeOptions -> IO ()
compile psc@PSCMakeOptions{..} = do
  putStrLn "Compiling project...."
  input <- globWarningOnMisses (unless pscmJSONErrors . warnFileTypeNotFound) pscmInput
  when (null input && not pscmJSONErrors) $ do
    hPutStr stderr $ unlines [ "purs compile: No input files."
                             , "Usage: For basic information, try the `--help' option."
                             ]
    exitFailure
  fpRef <- newIORef (M.empty, M.empty)
  (externs, sorted, graph, prebuilt) <- compileF psc input fpRef
  putStrLn "Compiling completed...."
  if pscmWatch
     then do
        emptyVar <- newEmptyMVar
        putMVar emptyVar (externs, sorted, graph, prebuilt)

        errorRef <- newIORef ([], False)
        withManager $ \mgr -> do
          watchTree
            mgr
            "./src"
            (const True)
            (recompile psc emptyVar fpRef errorRef)
          forever $ threadDelay 1000000
     else exitSuccess

recompile
  :: PSCMakeOptions
  -> MVar ([P.ExternsFile], [P.Module], P.ModuleGraph, M.Map P.ModuleName Prebuilt)
  -> IORef (M.Map P.ModuleName (Either RebuildPolicy FilePath)
           , M.Map P.ModuleName FilePath
           )
  -> IORef ([P.ModuleName], Bool)
  -> Event
  -> IO ()
recompile PSCMakeOptions{..} mvar fpRef errorRef event = do
  let fp = eventPath event
  putStrLn "recompiling ..."

  moduleFiles <- readInput [fp]

  prev <- takeMVar mvar

  (errModuleNames, prE) <- readIORef errorRef
  (oldFp, oldForeign) <- readIORef fpRef

  errCaseModules <- if not $ null errModuleNames
                      then readInput $ getFilePaths errModuleNames oldFp fp
                      else return []

  (makeErrors, makeWarnings) <- runMake pscmOpts $ do
    ms <- P.parseModulesFromFiles id moduleFiles

    let filePathMap = M.fromList $ map (\(mfp, P.Module _ _ mn _ _) -> (mn, Right mfp)) ms
    foreigns <- inferForeignModules filePathMap

    let makeActions = buildMakeActions pscmOutputDir oldFp oldForeign pscmUsePrefix
    (a, b, c, d, e) <- P.make makeActions (map snd ms) (Just prev) prE pscmWatch

    liftIO $ putMVar mvar (a, b, c, d)

    oldMs <- if null errCaseModules
                then return []
                else P.parseModulesFromFiles id errCaseModules

    let nextModules m = flip union m . map snd $ oldMs

    (a', b', c', d', _) <- P.make makeActions (nextModules e) (Just (a, (nextModules b), c, d)) prE pscmWatch

    return $ (a', b', c', d')

  (errs, prevS) <-
    printWarningsAndErrors (P.optionsVerboseErrors pscmOpts) pscmWarnings pscmJSONErrors makeWarnings makeErrors

  case prevS of
    Just x -> do
      _ <- takeMVar mvar
      putMVar mvar x
      writeIORef errorRef (errs, False)
    Nothing -> do
      isE <- isEmptyMVar mvar
      when isE $ putMVar mvar prev
      writeIORef errorRef (errs, True)

  putStrLn "recompiling completed ..."

compileF ::
    PSCMakeOptions
    -> [FilePath]
    -> IORef (M.Map P.ModuleName (Either RebuildPolicy FilePath)
           , M.Map P.ModuleName FilePath
           )
    -> IO ([P.ExternsFile], [P.Module], P.ModuleGraph, M.Map P.ModuleName Prebuilt)
compileF PSCMakeOptions {..} input fpRef = do
  moduleFiles <- readInput input
  (makeErrors, makeWarnings) <- runMake pscmOpts $ do
    ms <- P.parseModulesFromFiles id moduleFiles

    let filePathMap = M.fromList $ map (\(fp, P.Module _ _ mn _ _) -> (mn, Right fp)) ms
    foreigns <- inferForeignModules filePathMap

    when pscmWatch $ liftIO $ writeIORef fpRef (filePathMap, foreigns)

    let makeActions = buildMakeActions pscmOutputDir filePathMap foreigns pscmUsePrefix
    (a, b, c, d, _) <- P.make makeActions (map snd ms) Nothing False pscmWatch

    return $ (a, b, c, d)

  (_, bo) <-
    printWarningsAndErrors (P.optionsVerboseErrors pscmOpts) pscmWarnings pscmJSONErrors makeWarnings makeErrors
  when (isNothing bo) $ exitFailure
  return $ fromJust bo

warnFileTypeNotFound :: String -> IO ()
warnFileTypeNotFound = hPutStrLn stderr . ("purs compile: No files found using pattern: " ++)

globWarningOnMisses :: (String -> IO ()) -> [FilePath] -> IO [FilePath]
globWarningOnMisses warn = concatMapM globWithWarning
  where
  globWithWarning pattern' = do
    paths <- glob pattern'
    when (null paths) $ warn pattern'
    return paths
  concatMapM f = fmap concat . mapM f

readInput :: [FilePath] -> IO [(FilePath, Text)]
readInput inputFiles = forM inputFiles $ \inFile -> (inFile, ) <$> readUTF8FileT inFile

getFilePaths :: [P.ModuleName] -> M.Map P.ModuleName (Either RebuildPolicy FilePath) -> FilePath -> [FilePath]
getFilePaths ms oldMap fp = do
  let lookupResult mn =
            either
              (P.internalError "make: module not found in results")
              id
              (fromJust $ M.lookup mn oldMap)

  filter ((/=) fp) $ map lookupResult ms

inputFile :: Opts.Parser FilePath
inputFile = Opts.strArgument $
     Opts.metavar "FILE"
  <> Opts.help "The input .purs file(s)"

outputDirectory :: Opts.Parser FilePath
outputDirectory = Opts.strOption $
     Opts.short 'o'
  <> Opts.long "output"
  <> Opts.value "output"
  <> Opts.showDefault
  <> Opts.help "The output directory"

comments :: Opts.Parser Bool
comments = Opts.switch $
     Opts.short 'c'
  <> Opts.long "comments"
  <> Opts.help "Include comments in the generated code"

verboseErrors :: Opts.Parser Bool
verboseErrors = Opts.switch $
     Opts.short 'v'
  <> Opts.long "verbose-errors"
  <> Opts.help "Display verbose error messages"

noPrefix :: Opts.Parser Bool
noPrefix = Opts.switch $
     Opts.short 'p'
  <> Opts.long "no-prefix"
  <> Opts.help "Do not include comment header"

jsonErrors :: Opts.Parser Bool
jsonErrors = Opts.switch $
     Opts.long "json-errors"
  <> Opts.help "Print errors to stderr as JSON"

isWatch :: Opts.Parser Bool
isWatch = Opts.switch $
     Opts.long "watch"
  <> Opts.help "Watch source map"

isWarningsDisabled :: Opts.Parser Bool
isWarningsDisabled = Opts.switch $
     Opts.short 'w'
  <> Opts.long "disable-warnings"
  <> Opts.help "Disable display of warnings"

sourceMaps :: Opts.Parser Bool
sourceMaps = Opts.switch $
     Opts.long "source-maps"
  <> Opts.help "Generate source maps"

dumpCoreFn :: Opts.Parser Bool
dumpCoreFn = Opts.switch $
     Opts.long "dump-corefn"
  <> Opts.help "Dump the (functional) core representation of the compiled code at output/*/corefn.json"

options :: Opts.Parser P.Options
options = P.Options <$> verboseErrors
                    <*> (not <$> comments)
                    <*> sourceMaps
                    <*> dumpCoreFn

pscMakeOptions :: Opts.Parser PSCMakeOptions
pscMakeOptions = PSCMakeOptions <$> many inputFile
                                <*> outputDirectory
                                <*> options
                                <*> (not <$> noPrefix)
                                <*> jsonErrors
                                <*> isWatch
                                <*> isWarningsDisabled

command :: Opts.Parser (IO ())
command = compile <$> (Opts.helper <*> pscMakeOptions)
