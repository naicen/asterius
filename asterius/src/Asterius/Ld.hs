{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Asterius.Ld
  ( LinkTask (..),
    linkModules,
    linkExeInMemory,
    linkExe,
    rtsUsedSymbols,
  )
where

import Asterius.Ar
import Asterius.Binary.File
import Asterius.Binary.NameCache
import Asterius.Builtins
import Asterius.Builtins.Main
import Asterius.Resolve
import Asterius.Types
import qualified Asterius.Types.SymbolSet as SS
import Control.Exception
import Data.Traversable

data LinkTask
  = LinkTask
      { progName, linkOutput :: FilePath,
        linkObjs, linkLibs :: [FilePath],
        linkModule :: AsteriusRepModule,
        hasMain, debug, gcSections, verboseErr :: Bool,
        outputIR :: Maybe FilePath,
        rootSymbols, exportFunctions :: [EntitySymbol]
      }
  deriving (Show)

{-
Note [Malformed object files]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Object files in Haskell package directories can also originate from gcc being
called on cbits in packages. This in the past gave deserialization failures.
Hence, when we deserialize objects to be linked in 'loadTheWorld', we choose to
be overpermissive and silently ignore deserialization failures. This has worked
well so far.
-}

-- | Load all the library and object dependencies for a 'LinkTask' into a
-- single module.
loadTheWorld :: LinkTask -> IO AsteriusRepModule
loadTheWorld LinkTask {..} = do
  ncu <- newNameCacheUpdater
  libs <- for linkLibs (loadArchiveRep ncu)
  objs <- for linkObjs (loadObjectRep ncu)
  evaluate $ linkModule <> mconcat objs <> mconcat libs

-- | The *_info are generated from Cmm using the INFO_TABLE macro.
-- For example, see StgMiscClosures.cmm / Exception.cmm
rtsUsedSymbols :: SS.SymbolSet
rtsUsedSymbols =
  SS.fromList
    [ "barf",
      "base_AsteriusziTopHandler_runIO_closure",
      "base_AsteriusziTopHandler_runNonIO_closure",
      "base_AsteriusziTypesziJSException_mkJSException_closure",
      "base_GHCziPtr_Ptr_con_info",
      "ghczmprim_GHCziTypes_Czh_con_info",
      "ghczmprim_GHCziTypes_Dzh_con_info",
      "ghczmprim_GHCziTypes_False_closure",
      "ghczmprim_GHCziTypes_Izh_con_info",
      "ghczmprim_GHCziTypes_True_closure",
      "ghczmprim_GHCziTypes_Wzh_con_info",
      "ghczmprim_GHCziTypes_ZC_con_info",
      "ghczmprim_GHCziTypes_ZMZN_closure",
      "MainCapability",
      "stg_ARR_WORDS_info",
      "stg_BLACKHOLE_info",
      "stg_WHITEHOLE_info",
      "stg_IND_info",
      "stg_DEAD_WEAK_info",
      "stg_marked_upd_frame_info",
      "stg_NO_FINALIZER_closure",
      "stg_raise_info",
      "stg_raise_ret_info",
      "stg_STABLE_NAME_info",
      "stg_WEAK_info"
    ]

rtsPrivateSymbols :: SS.SymbolSet
rtsPrivateSymbols =
  SS.fromList
    [ "base_AsteriusziTopHandler_runIO_closure",
      "base_AsteriusziTopHandler_runNonIO_closure"
    ]

linkModules ::
  LinkTask -> AsteriusRepModule -> IO (AsteriusModule, Module, LinkReport)
linkModules LinkTask {..} module_rep =
  linkStart
    debug
    gcSections
    verboseErr
    ( toAsteriusRepModule
        ( (if hasMain then mainBuiltins else mempty)
            <> rtsAsteriusModule
              defaultBuiltinsOptions
                { Asterius.Builtins.progName = progName,
                  Asterius.Builtins.debug = debug
                }
        )
        <> module_rep
    )
    ( SS.unions
        [ SS.fromList rootSymbols,
          rtsUsedSymbols,
          rtsPrivateSymbols,
          SS.fromList
            [ mkEntitySymbol internalName
              | FunctionExport {..} <- rtsFunctionExports debug
            ]
        ]
    )
    exportFunctions

linkExeInMemory :: LinkTask -> IO (AsteriusModule, Module, LinkReport)
linkExeInMemory ld_task = do
  module_rep <- loadTheWorld ld_task
  linkModules ld_task module_rep

linkExe :: LinkTask -> IO ()
linkExe ld_task@LinkTask {..} = do
  (pre_m, m, link_report) <- linkExeInMemory ld_task
  putFile linkOutput (m, link_report)
  case outputIR of
    Just p -> putFile p $ inMemoryToOnDisk pre_m
    _ -> pure ()
