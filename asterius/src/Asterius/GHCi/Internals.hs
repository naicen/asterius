{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}

module Asterius.GHCi.Internals
  ( asteriusStartIServ,
    asteriusStopIServ,
    asteriusIservCall,
    asteriusReadIServ,
    asteriusWriteIServ,
    asteriusHscCompileCoreExpr,
  )
where

import Asterius.Ar
import Asterius.Binary.File
import Asterius.Binary.NameCache
import Asterius.BuildInfo
import Asterius.CodeGen
import Asterius.Internals.Name
import Asterius.Internals.Temp
import Asterius.JSRun.NonMain
import Asterius.Ld
import Asterius.Resolve
import Asterius.Types
import Asterius.Types.SymbolMap
import Asterius.TypesConv
import qualified BasicTypes as GHC
import qualified CLabel as GHC
import qualified CmmInfo as GHC
import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified CoreLint as GHC
import qualified CorePrep as GHC
import qualified CoreSyn as GHC
import qualified CoreTidy as GHC
import qualified CoreToStg as GHC
import qualified CoreUtils as GHC
import qualified CostCentre as GHC
import Data.Binary
import qualified Data.ByteString.Char8 as CBS
import qualified Data.ByteString.Lazy as LBS
import Data.Coerce
import Data.Data
  ( Data,
    gmapQl,
  )
import Data.IORef
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.String
import qualified ErrUtils as GHC
import qualified FastString as GHC
import Foreign.Ptr
import GHC.IO.Handle.FD
import qualified GHCi.Message as GHC
import GHCi.Message
import qualified GHCi.RemoteTypes as GHC
import qualified HscMain as GHC
import qualified HscTypes as GHC
import qualified Id as GHC
import qualified IdInfo as GHC
import qualified IfaceEnv as GHC
import Language.Haskell.TH
import Language.JavaScript.Inline.Core
import qualified Linker as GHC
import qualified Module as GHC
import qualified Name as GHC
import qualified Outputable as GHC
import qualified Packages as GHC
import qualified Panic as GHC
import qualified SimplCore as GHC
import qualified SimplStg as GHC
import qualified SrcLoc as GHC
import System.Directory
import System.Environment.Blank
import System.Exit
import System.FilePath
import System.IO
import System.IO.Unsafe
import System.Posix.Internals
import System.Process
import Type.Reflection
import qualified UniqDSet as GHC
import qualified UniqFM as GHC
import qualified UniqSupply as GHC
import Unsafe.Coerce
import qualified VarEnv as GHC

data GHCiState = GHCiState
  { ghciUniqSupply :: GHC.UniqSupply,
    ghciNameCacheUpdater :: GHC.NameCacheUpdater,
    ghciLibs :: AsteriusRepModule,
    ghciObjs :: M.Map FilePath AsteriusRepModule,
    ghciCompiledCoreExprs :: IM.IntMap (EntitySymbol, AsteriusRepModule),
    ghciLastCompiledCoreExpr :: Int,
    ghciSession :: ~(Session, Pipe, JSVal)
  }

{-# NOINLINE globalGHCiState #-}
globalGHCiState :: MVar GHCiState
globalGHCiState = unsafePerformIO $ do
  us <- GHC.mkSplitUniqSupply 'A'
  ncu <- newNameCacheUpdater
  newMVar
    GHCiState
      { ghciUniqSupply = us,
        ghciNameCacheUpdater = ncu,
        ghciLibs = mempty,
        ghciObjs = M.empty,
        ghciCompiledCoreExprs = IM.empty,
        ghciLastCompiledCoreExpr = 0,
        ghciSession = error "ghciSession not initialized"
      }

newGHCiSession :: IO (Session, Pipe)
newGHCiSession = do
  (node_read_fd, host_write_fd) <- createPipeFd
  (host_read_fd, node_write_fd) <- createPipeFd
  host_read_handle <- fdToHandle host_read_fd
  host_write_handle <- fdToHandle host_write_fd
  hSetBuffering host_read_handle NoBuffering
  hSetBuffering host_write_handle NoBuffering
  s <-
    newSession
      defaultConfig
        { nodeExtraArgs =
            [ "--experimental-wasm-return-call",
              "--no-wasm-bounds-checks",
              "--no-wasm-stack-checks",
              "--wasm-lazy-compilation",
              "--wasm-lazy-validation",
              "--wasm-max-mem-pages=65536"
            ],
          nodeExtraEnv =
            [ ("ASTERIUS_NODE_READ_FD", show node_read_fd),
              ("ASTERIUS_NODE_WRITE_FD", show node_write_fd)
            ],
          nodeExitOnEvalError = True
        }
  _ <- c_close node_read_fd
  _ <- c_close node_write_fd
  lo_ref <- newIORef Nothing
  pure
    ( s,
      Pipe
        { pipeRead = host_read_handle,
          pipeWrite = host_write_handle,
          pipeLeftovers = lo_ref
        }
    )

-- | Attempts to close the passed in 'Session', but won't throw in case of
-- exceptions. The parameter may come from an irrefutable pattern matching on an
-- uninitialized tuple.
tryCloseGHCiSession :: Session -> IO ()
tryCloseGHCiSession s = do
  (_ :: Either SomeException ()) <- try $ closeSession s
  pure ()

-- | Returns a dummy 'GHC.IServ' to GHC. We don't start a 'Session' yet; it is
-- only started upon 'GHC.RunTH' messages.
asteriusStartIServ :: GHC.HscEnv -> IO GHC.IServ
asteriusStartIServ hsc_env = do
  ignore <- isJust <$> getEnv "ASTERIUS_TH_IGNORE"
  when ignore exitFailure
  GHC.debugTraceMsg (GHC.hsc_dflags hsc_env) 3 $ GHC.text "asteriusStartIServ"
  cache_ref <- newIORef GHC.emptyUFM
  pure
    GHC.IServ
      { GHC.iservPipe = error "asteriusStartIServ.iservPipe",
        GHC.iservProcess = error "asteriusStartIServ.iservProcess",
        GHC.iservLookupSymbolCache = cache_ref,
        GHC.iservPendingFrees = []
      }

-- | Finalizes the global 'Session' if present.
asteriusStopIServ :: GHC.HscEnv -> IO ()
asteriusStopIServ hsc_env = do
  GHC.debugTraceMsg (GHC.hsc_dflags hsc_env) 3 $ GHC.text "asteriusStopIServ"
  modifyMVar_ globalGHCiState $ \s -> do
    let ~(js_s, _, _) = ghciSession s
    tryCloseGHCiSession js_s
    pure s {ghciSession = error "ghciSession already finalized"}

-- | Handles all 'GHC.Message's where the responses are synchronously returned.
-- The messages handled here are mainly related to linking.
asteriusIservCall ::
  Binary a => GHC.HscEnv -> GHC.IServ -> GHC.Message a -> IO a
asteriusIservCall hsc_env _ msg = do
  GHC.debugTraceMsg (GHC.hsc_dflags hsc_env) 3 $ GHC.text $ show msg
  case msg of
    GHC.InitLinker -> pure ()
    GHC.LoadDLL _ -> pure Nothing
    GHC.LoadArchive p -> modifyMVar_ globalGHCiState $ \s -> do
      lib <- loadArchiveRep (ghciNameCacheUpdater s) p
      evaluate s {ghciLibs = lib <> ghciLibs s}
    GHC.LoadObj p -> modifyMVar_ globalGHCiState $ \s -> do
      obj <- onDiskToObjRep p <$> getFile (ghciNameCacheUpdater s) p
      evaluate s {ghciObjs = M.insert p obj $ ghciObjs s}
    GHC.AddLibrarySearchPath _ -> pure $ GHC.RemotePtr 0
    GHC.RemoveLibrarySearchPath _ -> pure True
    GHC.ResolveObjs -> pure True
    GHC.FindSystemLibrary lib -> pure $ Just lib
    GHC.FreeHValueRefs _ -> pure ()
    GHC.StartTH -> pure $ unsafeCoerce $ GHC.RemotePtr 0
    _ -> fail "asteriusIservCall"

-- | When GHC expects to read something from the 'Pipe', it calls this function.
asteriusReadIServ ::
  forall a. (Binary a, Typeable a) => GHC.HscEnv -> GHC.IServ -> IO a
asteriusReadIServ _ _ = withMVar globalGHCiState $
  \s -> let (_, p, _) = ghciSession s in readPipe p get

-- | When GHC expects to write something to the 'Pipe', it calls this function.
-- We need to overload the 'Pipe' write logic and add special handlers for
-- specific variants of 'GHC.Message's, because the underlying @node@ process is
-- managed by @inline-js-core@ and isn't a true @iserv@ process, and while most
-- message passing are still done via the 'Pipe', some messages are really
-- implemented in the host @ahc@ process.
--
-- When GHC runs a TH splice, it issues a 'GHC.RunTH' message. Upon such a
-- message, we initialize a fresh 'Session' and assign it to our global linker
-- state (closing the previous one if possible), then combine the loaded
-- archives, objects and the Wasm code compiled from the 'GHC.CoreExpr' of the
-- splice, perform final linking, and load the emitted Wasm/JS code via
-- @inline-js-core@.
--
-- The logic of loading/running linked Wasm/JS code is implemented in the
-- 'asteriusRunTH' function. 'asteriusRunTH' returns a 'JSVal' which is the
-- @inline-js-core@ reference of the already initialized asterius instance. We
-- keep it along the 'Session' as a part of our global linker state, since it
-- may be used later when the TH module finalizer is invoked.
--
-- When all splices in a module are run, GHC issues a 'GHC.RunModFinalizers'
-- message, which is then handled by the 'asteriusRunModFinalizers' function. We
-- don't really run TH module finalizers for now; the @node@ side will simply
-- send a 'QDone' message back to make GHC happy. And since each 'GHC.RunTH'
-- message of a TH splice is handled by overwriting the global 'Session' (and
-- the 'JSVal' of the initialized asterius instance), the dummy TH module
-- finalizer is run by the 'Session' of the last TH splice of that module.
asteriusWriteIServ ::
  (Binary a, Typeable a) => GHC.HscEnv -> GHC.IServ -> a -> IO ()
asteriusWriteIServ hsc_env i a
  | Just HRefl <- eqTypeRep (typeOf a) (typeRep @GHC.Msg) = case a of
    GHC.Msg msg@(GHC.RunTH st q ty loc) -> do
      GHC.debugTraceMsg (GHC.hsc_dflags hsc_env) 3 $ GHC.text $ show msg
      modifyMVar_ globalGHCiState $ \s ->
        bracketOnError newGHCiSession (\(js_s, _) -> closeSession js_s) $
          \(new_js_s, new_p) -> do
            let ~(prev_js_s, _, _) = ghciSession s
            tryCloseGHCiSession prev_js_s
            pure
              s
                { ghciSession =
                    ( new_js_s,
                      new_p,
                      error "asterius instance not initialized"
                    )
                }
      modifyMVar_ globalGHCiState $ \s -> do
        let run_q_exp_sym =
              closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunQExp"
            run_q_pat_sym =
              closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunQPat"
            run_q_type_sym =
              closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunQType"
            run_q_dec_sym =
              closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunQDec"
            run_q_annwrapper_sym =
              closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunAnnWrapper"
            run_mod_fin_sym =
              closureSymbol
                hsc_env
                "ghci"
                "Asterius.GHCi"
                "asteriusRunModFinalizers"
            buf_conv_sym =
              closureSymbol
                hsc_env
                "asterius-prelude"
                "Asterius.ByteString"
                "byteStringFromJSUint8Array"
            this_id = remoteRefToInt q
            (sym, m) = ghciCompiledCoreExprs s IM.! this_id
            (js_s, p, _) = ghciSession s
        (_, final_m, link_report) <-
          linkExeInMemory
            LinkTask
              { progName = "",
                linkOutput = "",
                linkObjs = [],
                linkLibs = [],
                linkModule = m <> M.foldr' (<>) (ghciLibs s) (ghciObjs s),
                hasMain = False,
                debug = False,
                gcSections = True,
                verboseErr = True,
                outputIR = Nothing,
                rootSymbols =
                  [ run_q_exp_sym,
                    run_q_pat_sym,
                    run_q_type_sym,
                    run_q_dec_sym,
                    run_q_annwrapper_sym,
                    run_mod_fin_sym,
                    buf_conv_sym,
                    sym
                  ],
                exportFunctions = []
              }
        v <-
          asteriusRunTH
            hsc_env
            i
            st
            (fromIntegral (staticsSymbolMap link_report ! sym))
            ty
            loc
            js_s
            (final_m, link_report)
        pure
          s
            { ghciCompiledCoreExprs = IM.delete this_id $ ghciCompiledCoreExprs s,
              ghciSession = (js_s, p, v)
            }
    GHC.Msg m@GHC.RunModFinalizers {} -> do
      GHC.debugTraceMsg (GHC.hsc_dflags hsc_env) 3 $ GHC.text $ show m
      withMVar globalGHCiState $ \s -> do
        let (js_s, _, v) = ghciSession s
        asteriusRunModFinalizers hsc_env js_s v
    GHC.Msg m -> fail $ "asteriusWriteIServ: unsupported message " <> show m
  | otherwise = withMVar globalGHCiState $
    \s -> let (_, p, _) = ghciSession s in writePipe p $ put a

asteriusRunTH ::
  GHC.HscEnv ->
  GHC.IServ ->
  GHC.RemoteRef (IORef GHC.QState) ->
  Word64 ->
  GHC.THResultType ->
  Maybe Loc ->
  Session ->
  (Asterius.Types.Module, LinkReport) ->
  IO JSVal
asteriusRunTH hsc_env _ _ q ty loc s ahc_dist_input =
  withTempDir "asdf" $ \tmp_dir -> do
    let p = tmp_dir </> "asdf"
    distNonMain p [runner_sym, run_mod_fin_sym, buf_conv_sym] ahc_dist_input
    rts_val <- importMJS s $ dataDir </> "rts" </> "rts.mjs"
    mod_buf <- LBS.readFile $ p -<.> "wasm"
    req_mod_val <- importMJS s $ p -<.> "req.mjs"
    req_val <- evalJSVal s $ jsval req_mod_val <> ".default"
    buf_val <- evalJSVal s $ buffer mod_buf
    mod_val <- evalJSVal s $ "WebAssembly.compile(" <> jsval buf_val <> ")"
    i <-
      evalJSVal s $
        jsval rts_val
          <> ".newAsteriusInstance(Object.assign("
          <> jsval req_val
          <> ",{module:"
          <> jsval mod_val
          <> "}))"
    arr_buf <- evalJSVal s $ buffer (encode loc)
    let runner_closure =
          jsval i <> ".symbolTable."
            <> fromString
              (CBS.unpack (entityName runner_sym))
        buf_conv_closure =
          jsval i <> ".symbolTable."
            <> fromString
              (CBS.unpack (entityName buf_conv_sym))
        uint8_arr = "new Uint8Array(" <> jsval arr_buf <> ")"
        uint8_arr_sn =
          jsval i
            <> ".exports.context.stablePtrManager.newJSVal("
            <> uint8_arr
            <> ")"
        uint8_arr_closure =
          jsval i <> ".exports.rts_mkJSVal(" <> uint8_arr_sn <> ")"
        bs_closure =
          jsval i
            <> ".exports.rts_apply("
            <> buf_conv_closure
            <> ","
            <> uint8_arr_closure
            <> ")"
        runner_closure' =
          jsval i
            <> ".exports.rts_apply("
            <> runner_closure
            <> ","
            <> bs_closure
            <> ")"
        hv_closure = fromString $ show q
        applied_closure =
          jsval i
            <> ".exports.rts_apply("
            <> runner_closure'
            <> ","
            <> hv_closure
            <> ")"
        tid =
          jsval i <> ".exports.rts_evalLazyIO(" <> applied_closure <> ")"
    evalNone s tid
    evaluate i
  where
    runner_sym = closureSymbol hsc_env "ghci" "Asterius.GHCi" $ case ty of
      GHC.THExp -> "asteriusRunQExp"
      GHC.THPat -> "asteriusRunQPat"
      GHC.THType -> "asteriusRunQType"
      GHC.THDec -> "asteriusRunQDec"
      GHC.THAnnWrapper -> "asteriusRunAnnWrapper"
    run_mod_fin_sym =
      closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunModFinalizers"
    buf_conv_sym =
      closureSymbol
        hsc_env
        "asterius-prelude"
        "Asterius.ByteString"
        "byteStringFromJSUint8Array"

asteriusRunModFinalizers :: GHC.HscEnv -> Session -> JSVal -> IO ()
asteriusRunModFinalizers hsc_env s i = do
  let run_mod_fin_closure =
        jsval i <> ".symbolTable."
          <> fromString
            (CBS.unpack (entityName run_mod_fin_sym))
      tid =
        jsval i <> ".exports.rts_evalLazyIO(" <> run_mod_fin_closure <> ")"
  evalNone s tid
  pure ()
  where
    run_mod_fin_sym =
      closureSymbol hsc_env "ghci" "Asterius.GHCi" "asteriusRunModFinalizers"

-- | Compiles the 'GHC.CoreExpr' of a 'Q' splice to Cmm, then unlinked Wasm, and
-- returns the associated id as a 'GHC.ForeignHValue'. This is invoked by GHC
-- each time when a TH splice is run. The logic is largely based on
-- 'GHC.hscCompileCoreExpr', but we don't emit BCOs due to lack of BCO support.
--
-- When compiling a 'GHC.CoreExpr', we also link its dependencies; The linking
-- requests are handled by our 'asteriusIservCall' handler, which in turn
-- modifies our own global linker state, deserializes the required archives and
-- objects for future use. The final linking which combines the loaded archives,
-- objects, splices and produce a runnable Wasm bundle happens when the
-- 'GHC.RunTH' message is handled.
asteriusHscCompileCoreExpr ::
  GHC.HscEnv -> GHC.SrcSpan -> GHC.CoreExpr -> IO GHC.ForeignHValue
asteriusHscCompileCoreExpr hsc_env srcspan ds_expr = do
  let dflags = GHC.hsc_dflags hsc_env
  simpl_expr <- GHC.simplifyExpr dflags ds_expr
  let tidy_expr = GHC.tidyExpr GHC.emptyTidyEnv simpl_expr
  prepd_expr <- GHC.corePrepExpr dflags hsc_env tidy_expr
  GHC.lintInteractiveExpr "asteriusHscCompileCoreExpr" hsc_env prepd_expr
  linkRts hsc_env
  linkPkg hsc_env "ghci"
  linkPkg hsc_env "asterius-prelude"
  asteriusLinkExpr hsc_env srcspan prepd_expr
  u <- modifyMVar globalGHCiState $ \s ->
    let (u, s') = GHC.takeUniqFromSupply $ ghciUniqSupply s
     in pure (s {ghciUniqSupply = s'}, u)
  let this_mod =
        GHC.mkModule
          (GHC.stringToUnitId "asdf")
          (GHC.mkModuleName $ "ASDF" <> show u)
      occ_n = GHC.mkVarOcc "asdf"
      n = GHC.mkExternalName u this_mod occ_n srcspan
      clbl = GHC.mkClosureLabel n GHC.MayHaveCafRefs
      sym = fromString $ asmPpr dflags clbl
      b = GHC.mkVanillaGlobal n (GHC.exprType ds_expr)
      prepd_binds = [GHC.NonRec b prepd_expr]
      (stg_binds, _) = GHC.coreToStg dflags this_mod prepd_binds
  stg_binds2 <- GHC.stg2stg dflags this_mod stg_binds
  cmms <-
    GHC.doCodeGen
      hsc_env
      this_mod
      []
      GHC.emptyCollectedCCs
      stg_binds2
      (GHC.emptyHpcInfo False)
  raw_cmms <- GHC.cmmToRawCmm dflags (Just this_mod) cmms
  m <-
    runCodeGen (marshalRawCmm this_mod raw_cmms) dflags this_mod
      >>= either throwIO pure
  this_id <- modifyMVar globalGHCiState $ \s -> do
    let this_id = succ $ ghciLastCompiledCoreExpr s
    pure
      ( s
          { ghciCompiledCoreExprs =
              IM.insert this_id (sym, toAsteriusRepModule m) $
                ghciCompiledCoreExprs s,
            ghciLastCompiledCoreExpr = this_id
          },
        this_id
      )
  GHC.mkForeignRef (intToRemoteRef this_id) (pure ())

asteriusLinkExpr :: GHC.HscEnv -> GHC.SrcSpan -> GHC.CoreExpr -> IO ()
asteriusLinkExpr hsc_env srcspan prepd_expr = do
  GHC.initDynLinker hsc_env
  GHC.modifyPLS $ \pls0 -> do
    (pls, ok) <-
      GHC.linkDependencies hsc_env pls0 srcspan $
        neededModules prepd_expr
    if GHC.failed ok
      then GHC.throwGhcExceptionIO (GHC.ProgramError "")
      else pure (pls, ())

neededModules :: Data a => a -> [GHC.Module]
neededModules = GHC.uniqDSetToList . w
  where
    w :: Data a => a -> GHC.UniqDSet GHC.Module
    w t
      | Just HRefl <- eqTypeRep (typeOf t) (typeRep @GHC.CoreBndr) =
        let n = GHC.getName t
         in case GHC.nameModule_maybe n of
              Just m
                | GHC.isExternalName n && not (GHC.isWiredInName n) ->
                  GHC.unitUniqDSet m
              _ -> GHC.emptyUniqDSet
      | otherwise =
        gmapQl GHC.unionUniqDSets GHC.emptyUniqDSet w t

linkRts :: GHC.HscEnv -> IO ()
linkRts hsc_env = do
  let Just pkg_cfg =
        GHC.lookupInstalledPackage
          (GHC.hsc_dflags hsc_env)
          (GHC.toInstalledUnitId GHC.rtsUnitId)
  Just rts_path <- findFile (GHC.libraryDirs pkg_cfg) "libHSrts.a"
  asteriusIservCall hsc_env (error "linkRts") $ GHC.LoadArchive rts_path

linkPkg :: GHC.HscEnv -> GHC.FastString -> IO ()
linkPkg hsc_env pkg_name =
  GHC.linkPackages
    hsc_env
    [GHC.componentIdToInstalledUnitId comp_id]
  where
    Just comp_id =
      GHC.lookupPackageName (GHC.hsc_dflags hsc_env) (GHC.PackageName pkg_name)

closureSymbol :: GHC.HscEnv -> String -> String -> String -> EntitySymbol
closureSymbol hsc_env = fakeClosureSymbol (GHC.hsc_dflags hsc_env)

intToRemoteRef :: Int -> GHC.RemoteRef a
intToRemoteRef = unsafeCoerce . GHC.toRemotePtr . intPtrToPtr . coerce

remoteRefToInt :: GHC.RemoteRef a -> Int
remoteRefToInt = coerce . ptrToIntPtr . GHC.fromRemotePtr . unsafeCoerce
