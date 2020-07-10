{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module Asterius.Types
  ( BinaryenIndex,
    AsteriusCodeGenError (..),
    AsteriusStatic (..),
    AsteriusStaticsType (..),
    AsteriusStatics (..),
    AsteriusModule (..),
    AsteriusOnDiskModule (..),
    onDiskToInMemory,
    inMemoryToOnDisk,
    onDiskToObjRep,
    AsteriusRepModule (..),
    toAsteriusRepModule,
    loadObjectRep,
    loadObjectFile,
    EntitySymbol,
    entityName,
    mkEntitySymbol,
    UnresolvedLocalReg (..),
    UnresolvedGlobalReg (..),
    ValueType (..),
    FunctionType (..),
    UnaryOp (..),
    BinaryOp (..),
    Expression (..),
    Function (..),
    FunctionImport (..),
    TableImport (..),
    MemoryImport (..),
    FunctionExport (..),
    FunctionTable (..),
    DataSegment (..),
    Module (..),
    RelooperAddBlock (..),
    RelooperAddBranch (..),
    RelooperBlock (..),
    unreachableRelooperBlock,
    RelooperRun (..),
    FFIValueTypeRep (..),
    FFIValueType (..),
    FFIFunctionType (..),
    FFISafety (..),
    FFIImportDecl (..),
    FFIExportDecl (..),
    FFIMarshalState (..),
  )
where

import Asterius.Binary.File
import Asterius.Binary.Orphans ()
import Asterius.Binary.TH
import Asterius.Monoid.TH
import Asterius.NFData.TH
import Asterius.Semigroup.TH
import Asterius.Types.EntitySymbol
import Asterius.Types.SymbolMap (SymbolMap)
import qualified Asterius.Types.SymbolMap as SM
import Asterius.Types.SymbolSet (SymbolSet)
import qualified Asterius.Types.SymbolSet as SS
import qualified Binary as GHC
import Control.Exception
import Control.Monad
import qualified Data.ByteString as BS
import Data.Data
import Data.Foldable
import qualified Data.Map.Lazy as LM
import qualified Data.Set as Set
import Foreign
import qualified IfaceEnv as GHC
import qualified Type.Reflection as TR

type BinaryenIndex = Word32

data AsteriusCodeGenError
  = UnsupportedCmmLit BS.ByteString
  | UnsupportedCmmInstr BS.ByteString
  | UnsupportedCmmBranch BS.ByteString
  | UnsupportedCmmType BS.ByteString
  | UnsupportedCmmWidth BS.ByteString
  | UnsupportedCmmGlobalReg BS.ByteString
  | UnsupportedCmmExpr BS.ByteString
  | UnsupportedCmmSectionType BS.ByteString
  | UnsupportedImplicitCasting Expression ValueType ValueType
  | AssignToImmutableGlobalReg UnresolvedGlobalReg
  deriving (Show, Data)

instance Exception AsteriusCodeGenError

data AsteriusStatic
  = SymbolStatic EntitySymbol Int
  | Uninitialized Int
  | Serialized BS.ByteString
  deriving (Show, Data)

data AsteriusStaticsType
  = ConstBytes
  | Bytes
  | InfoTable
  | Closure
  deriving (Eq, Show, Data)

data AsteriusStatics
  = AsteriusStatics
      { staticsType :: AsteriusStaticsType,
        asteriusStatics :: [AsteriusStatic]
      }
  deriving (Show, Data)

----------------------------------------------------------------------------

data AsteriusModule
  = AsteriusModule
      { staticsMap :: SymbolMap AsteriusStatics,
        functionMap :: SymbolMap Function,
        sptMap :: SymbolMap (Word64, Word64),
        ffiMarshalState :: FFIMarshalState
      }
  deriving (Show, Data)

----------------------------------------------------------------------------

mkModuleExports :: AsteriusModule -> SymbolSet
mkModuleExports m =
  SS.fromList
    [ ffiExportClosure
      | FFIExportDecl {..} <-
          SM.elems
            $ ffiExportDecls
            $ ffiMarshalState m
    ]

mkModuleDependencyMap :: AsteriusModule -> SymbolMap SymbolSet
mkModuleDependencyMap m =
  mkDependencyMap (staticsMap m) <> mkDependencyMap (functionMap m)
  where
    mkDependencyMap :: Data a => SymbolMap a -> SymbolMap SymbolSet
    mkDependencyMap = flip SM.foldrWithKey' SM.empty $ \k e ->
      SM.insert k (collectEntitySymbols e)
    -- Collect all entity symbols from an entity.
    collectEntitySymbols :: Data a => a -> SymbolSet
    collectEntitySymbols t
      | Just TR.HRefl <- TR.eqTypeRep (TR.typeOf t) (TR.typeRep @EntitySymbol) =
        SS.singleton t
      | otherwise =
        gmapQl (<>) SS.empty collectEntitySymbols t

----------------------------------------------------------------------------

-- | Load the representation of an object file from disk.
loadObjectRep :: GHC.NameCacheUpdater -> FilePath -> IO AsteriusRepModule
loadObjectRep ncu path = tryGetFile ncu path >>= \case
  Left {} -> pure mempty -- Note [Malformed object files] in Asterius.Ld
  Right m -> pure $ onDiskToObjRep path m

-- | Load a module in its entirety from disk.
loadObjectFile :: GHC.NameCacheUpdater -> FilePath -> IO AsteriusModule
loadObjectFile ncu path = tryGetFile ncu path >>= \case
  Left {} -> pure mempty -- Note [Malformed object files] in Asterius.Ld
  Right m -> pure $ onDiskToInMemory m

----------------------------------------------------------------------------

-- | Asterius modules, as represented on disk.
data AsteriusOnDiskModule
  = AsteriusOnDiskModule
      { onDiskDependencyMap :: ~(SymbolMap SymbolSet),
        onDiskModuleExports :: ~SymbolSet,
        onDiskStaticsMap :: ~(SymbolMap AsteriusStatics),
        onDiskFunctionMap :: ~(SymbolMap Function),
        onDiskSptMap :: ~(SymbolMap (Word64, Word64)),
        onDiskFFIMarshalState :: ~FFIMarshalState
      }
  deriving (Show, Data)

instance GHC.Binary AsteriusOnDiskModule where
  get bh = do
    getObjectMagic bh
    onDiskDependencyMap <- GHC.lazyGet bh
    onDiskModuleExports <- GHC.lazyGet bh
    onDiskStaticsMap <- GHC.lazyGet bh
    onDiskFunctionMap <- GHC.lazyGet bh
    onDiskSptMap <- GHC.lazyGet bh
    onDiskFFIMarshalState <- GHC.lazyGet bh
    return AsteriusOnDiskModule {..}

  put_ bh AsteriusOnDiskModule {..} = do
    putObjectMagic bh
    GHC.lazyPut bh onDiskDependencyMap
    GHC.lazyPut bh onDiskModuleExports
    GHC.lazyPut bh onDiskStaticsMap
    GHC.lazyPut bh onDiskFunctionMap
    GHC.lazyPut bh onDiskSptMap
    GHC.lazyPut bh onDiskFFIMarshalState

objectMagic :: BS.ByteString
objectMagic = "!<asterius>\n"

putObjectMagic :: GHC.BinHandle -> IO ()
putObjectMagic bh = for_ (BS.unpack objectMagic) (GHC.putByte bh)

getObjectMagic :: GHC.BinHandle -> IO ()
getObjectMagic bh = do
  magic <- replicateM (BS.length objectMagic) (GHC.getByte bh)
  when (BS.pack magic /= objectMagic) $
    fail "Not an Asterius object file."

onDiskToInMemory :: AsteriusOnDiskModule -> AsteriusModule
onDiskToInMemory AsteriusOnDiskModule {..} =
  AsteriusModule
    { staticsMap = onDiskStaticsMap,
      functionMap = onDiskFunctionMap,
      sptMap = onDiskSptMap,
      ffiMarshalState = onDiskFFIMarshalState
    }

inMemoryToOnDisk :: AsteriusModule -> AsteriusOnDiskModule
inMemoryToOnDisk m@AsteriusModule {..} =
  AsteriusOnDiskModule
    { onDiskDependencyMap = mkModuleDependencyMap m,
      onDiskModuleExports = mkModuleExports m,
      onDiskStaticsMap = staticsMap,
      onDiskFunctionMap = functionMap,
      onDiskSptMap = sptMap,
      onDiskFFIMarshalState = ffiMarshalState
    }

onDiskToObjRep :: FilePath -> AsteriusOnDiskModule -> AsteriusRepModule
onDiskToObjRep obj_path m =
  AsteriusRepModule
    { dependencyMap = onDiskDependencyMap m,
      moduleExports = onDiskModuleExports m,
      objectSources = Set.singleton obj_path,
      archiveSources = mempty,
      inMemoryModule = mempty
    }

----------------------------------------------------------------------------

-- | An 'AsteriusRepModule' is the representation of an 'AsteriusModule' before
-- @gcSections@ has processed it. This representation is supposed to capture
-- __all__ data, whether it comes from object files, archive files, or
-- in-memory entities created using our EDSL.
data AsteriusRepModule
  = AsteriusRepModule
      { -- | (Cached, on disk) 'EntitySymbol' dependencies.
        dependencyMap :: SymbolMap SymbolSet,
        -- | (Cached, on disk) Exported symbols.
        moduleExports :: SymbolSet,
        -- | (not on disk) Object file dependencies.
        objectSources :: Set.Set FilePath,
        -- | (not on disk) Archive file dependencies.
        archiveSources :: Set.Set FilePath,
        -- | (not on disk) In-memory parts of the module that are not yet stored anywhere on disk yet.
        inMemoryModule :: AsteriusModule
      }
  deriving (Show, Data)

-- | Convert an 'AsteriusModule' to an 'AsteriusRepModule' by laboriously
-- computing the dependency graph for each 'EntitySymbol' and all the
-- 'EntitySymbol's the module exports.
toAsteriusRepModule :: AsteriusModule -> AsteriusRepModule
toAsteriusRepModule m =
  AsteriusRepModule
    { dependencyMap = mkModuleDependencyMap m,
      moduleExports = mkModuleExports m,
      objectSources = mempty,
      archiveSources = mempty,
      inMemoryModule = m
    }

----------------------------------------------------------------------------

data UnresolvedLocalReg
  = UniqueLocalReg Int ValueType
  | QuotRemI32X
  | QuotRemI32Y
  | QuotRemI64X
  | QuotRemI64Y
  deriving (Eq, Ord, Show, Data)

data UnresolvedGlobalReg
  = VanillaReg Int
  | FloatReg Int
  | DoubleReg Int
  | LongReg Int
  | Sp
  | SpLim
  | Hp
  | HpLim
  | CCCS
  | CurrentTSO
  | CurrentNursery
  | HpAlloc
  | EagerBlackholeInfo
  | GCEnter1
  | GCFun
  | BaseReg
  deriving (Show, Data)

data ValueType
  = I32
  | I64
  | F32
  | F64
  deriving (Eq, Ord, Enum, Show, Data)

data FunctionType
  = FunctionType
      { paramTypes, returnTypes :: [ValueType]
      }
  deriving (Eq, Ord, Show, Data)

data UnaryOp
  = ClzInt32
  | CtzInt32
  | PopcntInt32
  | NegFloat32
  | AbsFloat32
  | CeilFloat32
  | FloorFloat32
  | TruncFloat32
  | NearestFloat32
  | SqrtFloat32
  | EqZInt32
  | ClzInt64
  | CtzInt64
  | PopcntInt64
  | NegFloat64
  | AbsFloat64
  | CeilFloat64
  | FloorFloat64
  | TruncFloat64
  | NearestFloat64
  | SqrtFloat64
  | EqZInt64
  | ExtendSInt32
  | ExtendUInt32
  | WrapInt64
  | TruncSFloat32ToInt32
  | TruncSFloat32ToInt64
  | TruncUFloat32ToInt32
  | TruncUFloat32ToInt64
  | TruncSFloat64ToInt32
  | TruncSFloat64ToInt64
  | TruncUFloat64ToInt32
  | TruncUFloat64ToInt64
  | ReinterpretFloat32
  | ReinterpretFloat64
  | ConvertSInt32ToFloat32
  | ConvertSInt32ToFloat64
  | ConvertUInt32ToFloat32
  | ConvertUInt32ToFloat64
  | ConvertSInt64ToFloat32
  | ConvertSInt64ToFloat64
  | ConvertUInt64ToFloat32
  | ConvertUInt64ToFloat64
  | PromoteFloat32
  | DemoteFloat64
  | ReinterpretInt32
  | ReinterpretInt64
  deriving (Show, Data)

data BinaryOp
  = AddInt32
  | SubInt32
  | MulInt32
  | DivSInt32
  | DivUInt32
  | RemSInt32
  | RemUInt32
  | AndInt32
  | OrInt32
  | XorInt32
  | ShlInt32
  | ShrUInt32
  | ShrSInt32
  | RotLInt32
  | RotRInt32
  | EqInt32
  | NeInt32
  | LtSInt32
  | LtUInt32
  | LeSInt32
  | LeUInt32
  | GtSInt32
  | GtUInt32
  | GeSInt32
  | GeUInt32
  | AddInt64
  | SubInt64
  | MulInt64
  | DivSInt64
  | DivUInt64
  | RemSInt64
  | RemUInt64
  | AndInt64
  | OrInt64
  | XorInt64
  | ShlInt64
  | ShrUInt64
  | ShrSInt64
  | RotLInt64
  | RotRInt64
  | EqInt64
  | NeInt64
  | LtSInt64
  | LtUInt64
  | LeSInt64
  | LeUInt64
  | GtSInt64
  | GtUInt64
  | GeSInt64
  | GeUInt64
  | AddFloat32
  | SubFloat32
  | MulFloat32
  | DivFloat32
  | CopySignFloat32
  | MinFloat32
  | MaxFloat32
  | EqFloat32
  | NeFloat32
  | LtFloat32
  | LeFloat32
  | GtFloat32
  | GeFloat32
  | AddFloat64
  | SubFloat64
  | MulFloat64
  | DivFloat64
  | CopySignFloat64
  | MinFloat64
  | MaxFloat64
  | EqFloat64
  | NeFloat64
  | LtFloat64
  | LeFloat64
  | GtFloat64
  | GeFloat64
  deriving (Show, Data)

data Expression
  = Block
      { name :: BS.ByteString,
        bodys :: [Expression],
        blockReturnTypes :: [ValueType]
      }
  | If
      { condition, ifTrue :: Expression,
        ifFalse :: Maybe Expression
      }
  | Loop
      { name :: BS.ByteString,
        body :: Expression
      }
  | Break
      { name :: BS.ByteString,
        breakCondition :: Maybe Expression
      }
  | Switch
      { names :: [BS.ByteString],
        defaultName :: BS.ByteString,
        condition :: Expression
      }
  | Call
      { target :: EntitySymbol,
        operands :: [Expression],
        callReturnTypes :: [ValueType]
      }
  | CallImport
      { target' :: BS.ByteString,
        operands :: [Expression],
        callImportReturnTypes :: [ValueType]
      }
  | CallIndirect
      { indirectTarget :: Expression,
        operands :: [Expression],
        functionType :: FunctionType
      }
  | GetLocal
      { index :: BinaryenIndex,
        valueType :: ValueType
      }
  | SetLocal
      { index :: BinaryenIndex,
        value :: Expression
      }
  | TeeLocal
      { index :: BinaryenIndex,
        value :: Expression,
        valueType :: ValueType
      }
  | Load
      { signed :: Bool,
        bytes, offset :: BinaryenIndex,
        valueType :: ValueType,
        ptr :: Expression
      }
  | Store
      { bytes, offset :: BinaryenIndex,
        ptr, value :: Expression,
        valueType :: ValueType
      }
  | ConstI32 Int32
  | ConstI64 Int64
  | ConstF32 Float
  | ConstF64 Double
  | Unary
      { unaryOp :: UnaryOp,
        operand0 :: Expression
      }
  | Binary
      { binaryOp :: BinaryOp,
        operand0, operand1 :: Expression
      }
  | Drop
      { dropValue :: Expression
      }
  | ReturnCall
      { returnCallTarget64 :: EntitySymbol
      }
  | ReturnCallIndirect
      { returnCallIndirectTarget64 :: Expression
      }
  | Nop
  | Unreachable
  | CFG
      { graph :: RelooperRun
      }
  | Symbol
      { unresolvedSymbol :: EntitySymbol,
        symbolOffset :: Int
      }
  | UnresolvedGetLocal
      { unresolvedLocalReg :: UnresolvedLocalReg
      }
  | UnresolvedSetLocal
      { unresolvedLocalReg :: UnresolvedLocalReg,
        value :: Expression
      }
  | Barf
      { barfMessage :: BS.ByteString,
        barfReturnTypes :: [ValueType]
      }
  deriving (Show, Data)

data Function
  = Function
      { functionType :: FunctionType,
        varTypes :: [ValueType],
        body :: Expression
      }
  deriving (Show, Data)

data FunctionImport
  = FunctionImport
      { internalName, externalModuleName, externalBaseName :: BS.ByteString,
        functionType :: FunctionType
      }
  deriving (Show, Data)

data TableImport
  = TableImport
      { externalModuleName, externalBaseName :: BS.ByteString
      }
  deriving (Show, Data)

data MemoryImport
  = MemoryImport
      { externalModuleName, externalBaseName :: BS.ByteString
      }
  deriving (Show, Data)

data FunctionExport
  = FunctionExport
      { internalName, externalName :: BS.ByteString
      }
  deriving (Show, Data)

data FunctionTable
  = FunctionTable
      { tableFunctionNames :: [BS.ByteString],
        tableOffset :: BinaryenIndex
      }
  deriving (Show, Data)

data DataSegment
  = DataSegment
      { content :: BS.ByteString,
        offset :: Int32
      }
  deriving (Show, Data)

data Module
  = Module
      { functionMap' :: LM.Map BS.ByteString Function,
        functionImports :: [FunctionImport],
        functionExports :: [FunctionExport],
        functionTable :: FunctionTable,
        tableImport :: TableImport,
        tableSlots :: Int,
        memorySegments :: [DataSegment],
        memoryImport :: MemoryImport,
        memoryMBlocks :: Int
      }
  deriving (Show, Data)

data RelooperAddBlock
  = AddBlock
      { code :: Expression
      }
  | AddBlockWithSwitch
      { code, condition :: Expression
      }
  deriving (Show, Data)

data RelooperAddBranch
  = AddBranch
      { to :: BS.ByteString,
        addBranchCondition :: Maybe Expression
      }
  | AddBranchForSwitch
      { to :: BS.ByteString,
        indexes :: [BinaryenIndex]
      }
  deriving (Show, Data)

data RelooperBlock
  = RelooperBlock
      { addBlock :: RelooperAddBlock,
        addBranches :: [RelooperAddBranch]
      }
  deriving (Show, Data)

-- | A 'RelooperBlock' containing a single 'Unreachable' instruction.
unreachableRelooperBlock :: RelooperBlock
unreachableRelooperBlock =
  RelooperBlock -- See Note [unreachableRelooperBlock]
    { addBlock =
        AddBlock
          { code = Unreachable
          },
      addBranches = []
    }

data RelooperRun
  = RelooperRun
      { entry :: BS.ByteString,
        blockMap :: LM.Map BS.ByteString RelooperBlock,
        labelHelper :: BinaryenIndex
      }
  deriving (Show, Data)

data FFIValueTypeRep
  = FFILiftedRep
  | FFIUnliftedRep
  | FFIJSValRep
  | FFIIntRep
  | FFIWordRep
  | FFIAddrRep
  | FFIFloatRep
  | FFIDoubleRep
  deriving (Show, Data)

data FFIValueType
  = FFIValueType
      { ffiValueTypeRep :: FFIValueTypeRep,
        hsTyCon :: BS.ByteString
      }
  deriving (Show, Data)

data FFIFunctionType
  = FFIFunctionType
      { ffiParamTypes, ffiResultTypes :: [FFIValueType],
        ffiInIO :: Bool
      }
  deriving (Show, Data)

data FFISafety
  = FFIUnsafe
  | FFISafe
  | FFIInterruptible
  deriving (Eq, Show, Data)

data FFIImportDecl
  = FFIImportDecl
      { ffiFunctionType :: FFIFunctionType,
        ffiSafety :: FFISafety,
        ffiSourceText :: BS.ByteString
      }
  deriving (Show, Data)

data FFIExportDecl
  = FFIExportDecl
      { ffiFunctionType :: FFIFunctionType,
        ffiExportClosure :: EntitySymbol
      }
  deriving (Show, Data)

data FFIMarshalState
  = FFIMarshalState
      { ffiImportDecls :: SymbolMap FFIImportDecl,
        ffiExportDecls :: SymbolMap FFIExportDecl
      }
  deriving (Show, Data)

-- NFData instances

$(genNFData ''AsteriusCodeGenError)

$(genNFData ''AsteriusStatic)

$(genNFData ''AsteriusStaticsType)

$(genNFData ''AsteriusStatics)

$(genNFData ''AsteriusModule)

$(genNFData ''AsteriusRepModule)

$(genNFData ''UnresolvedLocalReg)

$(genNFData ''UnresolvedGlobalReg)

$(genNFData ''ValueType)

$(genNFData ''FunctionType)

$(genNFData ''UnaryOp)

$(genNFData ''BinaryOp)

$(genNFData ''Expression)

$(genNFData ''Function)

$(genNFData ''FunctionImport)

$(genNFData ''TableImport)

$(genNFData ''MemoryImport)

$(genNFData ''FunctionExport)

$(genNFData ''FunctionTable)

$(genNFData ''DataSegment)

$(genNFData ''Module)

$(genNFData ''RelooperAddBlock)

$(genNFData ''RelooperAddBranch)

$(genNFData ''RelooperBlock)

$(genNFData ''RelooperRun)

$(genNFData ''FFIValueTypeRep)

$(genNFData ''FFIValueType)

$(genNFData ''FFIFunctionType)

$(genNFData ''FFISafety)

$(genNFData ''FFIImportDecl)

$(genNFData ''FFIExportDecl)

$(genNFData ''FFIMarshalState)

-- Binary instances

$(genBinary ''AsteriusCodeGenError)

$(genBinary ''AsteriusStatic)

$(genBinary ''AsteriusStaticsType)

$(genBinary ''AsteriusStatics)

$(genBinary ''UnresolvedLocalReg)

$(genBinary ''UnresolvedGlobalReg)

$(genBinary ''ValueType)

$(genBinary ''FunctionType)

$(genBinary ''UnaryOp)

$(genBinary ''BinaryOp)

$(genBinary ''Expression)

$(genBinary ''Function)

$(genBinary ''FunctionImport)

$(genBinary ''TableImport)

$(genBinary ''MemoryImport)

$(genBinary ''FunctionExport)

$(genBinary ''FunctionTable)

$(genBinary ''DataSegment)

$(genBinary ''Module)

$(genBinary ''RelooperAddBlock)

$(genBinary ''RelooperAddBranch)

$(genBinary ''RelooperBlock)

$(genBinary ''RelooperRun)

$(genBinary ''FFIValueTypeRep)

$(genBinary ''FFIValueType)

$(genBinary ''FFIFunctionType)

$(genBinary ''FFISafety)

$(genBinary ''FFIImportDecl)

$(genBinary ''FFIExportDecl)

$(genBinary ''FFIMarshalState)

-- Semigroup instances

$(genSemigroup ''AsteriusModule)

$(genSemigroup ''AsteriusRepModule)

$(genSemigroup ''FFIMarshalState)

-- Monoid instances

$(genMonoid ''AsteriusModule)

$(genMonoid ''AsteriusRepModule)

$(genMonoid ''FFIMarshalState)
