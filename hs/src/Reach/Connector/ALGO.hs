module Reach.Connector.ALGO (connect_algo) where

import Control.Monad.Identity
import Control.Monad.Reader
import qualified Data.Aeson as Aeson
import Data.ByteString.Base64 (encodeBase64')
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.DList as DL
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.IO as LTIO
import qualified Data.Vector as Vector
import Data.Word
import GHC.Stack (HasCallStack)
import Reach.AST.Base
import Reach.AST.DLBase
import Reach.AST.PL
import Reach.Connector
import Reach.Counter
import Reach.Texty (pretty)
import Reach.UnsafeUtil
import Reach.Util
import Safe (atMay)
import Text.Read

-- import Debug.Trace

-- Variable substitution
type SubstEnv = M.Map DLVar DLVar
type SubstApp = ReaderT SubstEnv Identity
type SubstT a = a -> SubstApp a

class Subst a where
  subst :: SubstT a

instance (Traversable f, Subst a) => Subst (f a) where
  subst = traverse subst

instance Subst DLVar where
  subst v = do
    m <- ask
    return $ fromMaybe v $ M.lookup v m

instance Subst DLArg where
  subst = \case
    DLA_Var v -> DLA_Var <$> subst v
    x -> return x

instance Subst DLLargeArg where
  subst = \case
    DLLA_Array t as -> DLLA_Array t <$> subst as
    DLLA_Tuple as -> DLLA_Tuple <$> subst as
    DLLA_Obj m -> DLLA_Obj <$> subst m
    DLLA_Data t v a -> DLLA_Data t v <$> subst a

instance Subst DLExpr where
  subst = \case
    DLE_Arg at a -> DLE_Arg at <$> subst a
    DLE_LArg at a -> DLE_LArg at <$> subst a
    e@(DLE_Impossible {}) -> return $ e
    DLE_PrimOp at p as -> DLE_PrimOp at p <$> subst as
    DLE_ArrayRef at a b -> DLE_ArrayRef at <$> subst a <*> subst b
    DLE_ArraySet at a b c -> DLE_ArraySet at <$> subst a <*> subst b <*> subst c
    DLE_ArrayConcat at a b -> DLE_ArrayConcat at <$> subst a <*> subst b
    DLE_ArrayZip at a b -> DLE_ArrayZip at <$> subst a <*> subst b
    DLE_TupleRef at x y -> DLE_TupleRef at <$> subst x <*> pure y
    DLE_ObjectRef at x y -> DLE_ObjectRef at <$> subst x <*> pure y
    DLE_Interact a b c d e f -> DLE_Interact a b c d e <$> subst f
    DLE_Digest at as -> DLE_Digest at <$> subst as
    DLE_Claim a b c d e -> DLE_Claim a b c <$> subst d <*> pure e
    DLE_Transfer at x y -> DLE_Transfer at <$> subst x <*> subst y
    DLE_Wait at x -> DLE_Wait at <$> subst x
    DLE_PartSet at x y -> DLE_PartSet at x <$> subst y

instance {-# OVERLAPPING #-} Subst (DLinStmt a) where
  subst = \case
    DL_Nop at -> return $ DL_Nop at
    DL_Let at v de -> DL_Let at v <$> subst de
    DL_ArrayMap at x a v bl ->
      DL_ArrayMap at x <$> subst a <*> pure v <*> subst bl
    DL_ArrayReduce at x a b u v bl ->
      DL_ArrayReduce at x <$> subst a <*> subst b <*> pure u <*> pure v <*> subst bl
    DL_Var at v -> return $ DL_Var at v
    DL_Set at v a -> DL_Set at v <$> subst a
    DL_LocalIf at c t f -> DL_LocalIf at <$> subst c <*> subst t <*> subst f
    DL_LocalSwitch at v csm -> DL_LocalSwitch at <$> subst v <*> subst csm

instance {-# OVERLAPPING #-} Subst (DLinTail a) where
  subst = \case
    DT_Return at -> return $ DT_Return at
    DT_Com m k -> DT_Com <$> subst m <*> subst k

instance {-# OVERLAPPING #-} Subst (DLinBlock a) where
  subst (DLinBlock at fs t a) = DLinBlock at fs <$> subst t <*> subst a

instance Subst DLAssignment where
  subst (DLAssignment m) = DLAssignment <$> subst m

instance Subst CTail where
  subst = \case
    CT_Com m k -> CT_Com <$> subst m <*> subst k
    CT_If at c t f -> CT_If at <$> subst c <*> subst t <*> subst f
    CT_Switch at v csm -> CT_Switch at <$> subst v <*> subst csm
    CT_From at msvs -> CT_From at <$> subst msvs
    CT_Jump at which svs asn -> CT_Jump at which <$> subst svs <*> subst asn

subst_ :: Subst a => SubstEnv -> a -> a
subst_ rho x = runIdentity $ flip runReaderT rho $ subst x

-- General tools that could be elsewhere

aarray :: [Aeson.Value] -> Aeson.Value
aarray = Aeson.Array . Vector.fromList

sb :: SrcLoc
sb = srcloc_builtin

typeArray :: HasCallStack => DLArg -> (DLType, Integer)
typeArray a =
  case argTypeOf a of
    T_Array t sz -> (t, sz)
    _ -> impossible $ "should be array"

typeTupleTypes :: HasCallStack => DLArg -> [DLType]
typeTupleTypes a =
  case argTypeOf a of
    T_Tuple ts -> ts
    _ -> impossible $ "should be tuple"

typeObjectTypes :: HasCallStack => DLArg -> [(SLVar, DLType)]
typeObjectTypes a =
  case argTypeOf a of
    T_Object m -> M.toAscList m
    _ -> impossible $ "should be obj"

-- Algo specific stuff

udiv :: Integer -> Integer -> Integer
udiv x y = z
  where
    (q, d) = quotRem x y
    z = if d == 0 then q else q + 1

typeSizeOf :: DLType -> Integer
typeSizeOf = \case
  T_Null -> 0
  T_Bool -> 1
  T_UInt -> word
  T_Bytes sz -> sz
  T_Digest -> 32
  T_Address -> 32
  T_Array t sz -> sz * typeSizeOf t
  T_Tuple ts -> sum $ map typeSizeOf ts
  T_Object m -> sum $ map typeSizeOf $ M.elems m
  T_Data m -> 1 + (maximum $ map typeSizeOf $ M.elems m)
  where
    word = 8

encodeBase64 :: B.ByteString -> LT.Text
encodeBase64 bs = LT.pack $ B.unpack $ encodeBase64' bs

texty :: Show a => a -> LT.Text
texty x = LT.pack $ show x

template :: LT.Text -> LT.Text
template x = "\"{{" <> x <> "}}\""

type ScratchSlot = Word8

type TxnIdx = Word8

type TEAL = [LT.Text]

code_ :: LT.Text -> [LT.Text] -> TEAL
code_ fun args = fun : args

label_ :: LT.Text -> TEAL
label_ lab = [lab <> ":"]

comment_ :: LT.Text -> TEAL
comment_ t = ["//", t]

type TEALs = DL.DList TEAL

optimize :: [TEAL] -> [TEAL]
optimize = \case
  [] -> []
  ["b", x] : b@[y] : l | y == (x <> ":") -> b : optimize l
  ["btoi"] : ["itob", "// bool"] : ["substring", "7", "8"] : l -> optimize l
  ["btoi"] : ["itob"] : l -> optimize l
  ["itob"] : ["btoi"] : l -> optimize l
  a@["store", x] : ["load", y] : l
    | x == y ->
      ["dup"] : optimize (a : l)
  a@["substring", s0, _] : b@["substring", s1, e1] : l ->
    case mse of
      Just (s2, e2) ->
        optimize $ ["substring", s2, e2] : l
      Nothing ->
        a : (optimize $ b : l)
    where
      mse = do
        s0n <- parse s0
        s1n <- parse s1
        e1n <- parse e1
        let s2n = s0n + s1n
        let e2n = s2n + e1n
        case s2n < 256 && e2n < 256 of
          True -> return $ (texty s2n, texty e2n)
          False -> mempty
  --a@["int", x] : b@["itob"] : l ->
  --  case itob x of
  --    Nothing ->
  --      a : (optimize $ b : l)
  --    Just xbs ->
  --      optimize $ ["byte", xbs ] : l
  x : l -> x : optimize l
  where
    parse :: LT.Text -> Maybe Integer
    parse = readMaybe . LT.unpack
    _itob :: LT.Text -> Maybe LT.Text
    _itob x_lt = do
      x <- parse x_lt
      let x_bs = LB.toStrict $ toLazyByteString $ word64BE $ fromIntegral x
      return $ base64d x_bs

render :: TEALs -> T.Text
render ts = tt
  where
    tt = LT.toStrict lt
    lt = LT.unlines lts
    lts = "#pragma version 2" : (map LT.unwords $ optimize $ DL.toList ts)

data Shared = Shared
  { sHandlers :: M.Map Int CHandler
  , sFailedR :: IORef Bool
  , sCounterR :: Counter
  }

type Lets = M.Map DLVar (App ())

data Env = Env
  { eShared :: Shared
  , eWhich :: Int
  , eLabelR :: IORef Int
  , eOutputR :: IORef TEALs
  , eTxnsR :: IORef TxnIdx
  , eHP :: ScratchSlot
  , eSP :: ScratchSlot
  , eVars :: M.Map DLVar ScratchSlot
  , eLets :: Lets
  , eLetSmalls :: M.Map DLVar Bool
  , emTimev :: Maybe DLVar
  }

-- I'd rather not embed in IO, but when I used ST in UnrollLoops, it was
-- really annoying to have the world parameter
type App = ReaderT Env IO

allocVar :: DLVar -> App DLVar
allocVar (DLVar at s t _) = do
  Env {..} <- ask
  let Shared {..} = eShared
  idx <- liftIO $ incCounter sCounterR
  return $ DLVar at s t idx

output :: TEAL -> App ()
output t = do
  Env {..} <- ask
  liftIO $ modifyIORef eOutputR (flip DL.snoc t)

code :: LT.Text -> [LT.Text] -> App ()
code f args = output $ code_ f args

label :: LT.Text -> App ()
label = output . label_

comment :: LT.Text -> App ()
comment = output . comment_

or_fail :: App ()
or_fail = op "assert"

eq_or_fail :: App ()
eq_or_fail = op "==" >> or_fail

op :: LT.Text -> App ()
op = flip code []

nop :: App ()
nop = return ()

app_global_get :: B.ByteString -> App ()
app_global_get k = do
  cl $ DLL_Bytes $ k
  op "app_global_get"

app_global_put :: B.ByteString -> App () -> App ()
app_global_put k mkv = do
  cl $ DLL_Bytes $ k
  mkv
  op "app_global_put"

check_rekeyto :: App ()
check_rekeyto = do
  code "txn" ["RekeyTo"]
  code "global" ["ZeroAddress"]
  eq_or_fail

bad_ :: App ()
bad_ = do
  Env {..} <- ask
  let Shared {..} = eShared
  liftIO $ writeIORef sFailedR True

bad :: LT.Text -> App ()
bad lab = do
  bad_
  output $ comment_ $ "BAD " <> lab

xxx :: LT.Text -> App ()
xxx lab = do
  let lab' = "XXX " <> lab
  when False $
    liftIO $ LTIO.putStrLn lab'
  bad lab'

freshLabel :: App LT.Text
freshLabel = do
  Env {..} <- ask
  i <- liftIO $ readIORef eLabelR
  liftIO $ modifyIORef eLabelR (1 +)
  return $ "l" <> LT.pack (show i)

store_let :: DLVar -> Bool -> App () -> App a -> App a
store_let dv small cgen m = do
  Env {..} <- ask
  local
    (\e ->
       e
         { eLets = M.insert dv cgen eLets
         , eLetSmalls = M.insert dv small eLetSmalls
         })
    $ m

letSmall :: DLVar -> App Bool
letSmall dv = do
  Env {..} <- ask
  return $ fromMaybe False (M.lookup dv eLetSmalls)

lookup_let :: DLVar -> App ()
lookup_let dv = do
  Env {..} <- ask
  case M.lookup dv eLets of
    Just m -> m
    Nothing ->
      impossible $ show eWhich <> " lookup_let " <> show (pretty dv) <> " not in " <> (intercalate ", " $ map (show . pretty) $ M.keys eLets)

store_var :: DLVar -> ScratchSlot -> App a -> App a
store_var dv ss m = do
  Env {..} <- ask
  local (\e -> e {eVars = M.insert dv ss eVars}) $
    m

lookup_var :: DLVar -> App ScratchSlot
lookup_var dv = do
  Env {..} <- ask
  case M.lookup dv eVars of
    Just x -> return $ x
    Nothing -> impossible $ "lookup_var " <> show dv

salloc :: (ScratchSlot -> App a) -> App a
salloc fm = do
  Env {..} <- ask
  let eSP' = eSP - 1
  when (eSP' == eHP) $ do
    bad "too much memory"
  local (\e -> e {eSP = eSP'}) $
    fm eSP

talloc :: App TxnIdx
talloc = do
  Env {..} <- ask
  liftIO $ modifyIORef eTxnsR (1 +)
  txni <- liftIO $ readIORef eTxnsR
  when (txni > 15) $ do
    bad "too many txns"
  return txni

how_many_txns :: App TxnIdx
how_many_txns = do
  Env {..} <- ask
  liftIO $ readIORef eTxnsR

ctobs :: DLType -> App ()
ctobs = \case
  T_UInt -> op "itob"
  T_Bool -> code "itob" ["// bool"] >> code "substring" ["7", "8"]
  T_Null -> nop
  T_Bytes _ -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop

cfrombs :: DLType -> App ()
cfrombs = \case
  T_UInt -> op "btoi"
  T_Bool -> op "btoi"
  T_Null -> nop
  T_Bytes _ -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop

tint :: SrcLoc -> Integer -> LT.Text
tint at i = texty $ checkIntLiteralC at connect_algo i

base64d :: B.ByteString -> LT.Text
base64d bs = "base64(" <> encodeBase64 bs <> ")"

cl :: DLLiteral -> App ()
cl = \case
  DLL_Null -> cl $ DLL_Bytes ""
  DLL_Bool b -> cl $ DLL_Int sb $ if b then 1 else 0
  DLL_Int at i -> code "int" [tint at i]
  DLL_Bytes bs -> code "byte" [base64d bs]

ca_boolb :: DLArg -> Maybe B.ByteString
ca_boolb = \case
  DLA_Literal (DLL_Bool b) ->
    Just $ B.singleton $ toEnum $ if b then 1 else 0
  _ -> Nothing

cas_boolbs :: [DLArg] -> Maybe B.ByteString
cas_boolbs = mconcat . map ca_boolb

ca :: DLArg -> App ()
ca = \case
  DLA_Var v -> lookup_let v
  DLA_Constant c -> cl $ conCons connect_algo c
  DLA_Literal c -> cl c
  DLA_Interact {} -> impossible "consensus interact"

argSmall :: DLArg -> App Bool
argSmall = \case
  DLA_Var v -> letSmall v
  DLA_Constant {} -> return True
  DLA_Literal {} -> return True
  DLA_Interact {} -> impossible "consensus interact"

exprSmall :: DLExpr -> App Bool
exprSmall = \case
  DLE_Arg _ a -> argSmall a
  _ -> return False

cprim :: PrimOp -> [DLArg] -> App ()
cprim = \case
  SELF_ADDRESS -> impossible "self address"
  ADD -> call "+"
  SUB -> call "-"
  MUL -> call "*"
  DIV -> call "/"
  MOD -> call "%"
  PLT -> call "<"
  PLE -> call "<="
  PEQ -> call "=="
  PGT -> call ">"
  PGE -> call ">="
  LSH -> call "<<"
  RSH -> call ">>"
  BAND -> call "&"
  BIOR -> call "|"
  BXOR -> call "^"
  DIGEST_EQ -> call "=="
  ADDRESS_EQ -> call "=="
  IF_THEN_ELSE -> \case
    [be, DLA_Literal (DLL_Bool True), DLA_Literal (DLL_Bool False)] -> do
      ca be
    [be, DLA_Literal (DLL_Bool False), DLA_Literal (DLL_Bool True)] -> do
      ca be
      op "!"
    [be, DLA_Literal (DLL_Bool True), fe] -> do
      ca be
      ca fe
      op "||"
    [be, DLA_Literal (DLL_Bool False), fe] -> do
      -- be \ fe |  T  | F
      --    T    |  F  | F
      --    F    |  T  | F
      ca be
      op "!"
      ca fe
      op "&&"
    [be, te, DLA_Literal (DLL_Bool False)] -> do
      ca be
      ca te
      op "&&"
    [be, te, DLA_Literal (DLL_Bool True)] -> do
      -- be \ te |  T  | F
      --    T    |  T  | F
      --    F    |  T  | T
      ca be
      op "!"
      ca te
      op "||"
    [be, te, fe] -> do
      ca be
      ca te
      ca fe
      op "ite"
    _ -> impossible "ite args"
  where
    call o = \args -> do
      forM_ args ca
      op o

csum_ :: [App ()] -> App ()
csum_ = \case
  [] -> cl $ DLL_Int sb 0
  [m] -> m
  m : ms -> csum_ ms >> m >> op "+"

csum :: [DLArg] -> App ()
csum = csum_ . map ca

cconcatbs :: [(DLType, App ())] -> App ()
cconcatbs l = do
  check_concat_len totlen
  mapM_ (uncurry go) $ zip (no_concat : repeat yes_concat) l
  where
    go may_concat (t, m) = m >> ctobs t >> may_concat
    no_concat = nop
    yes_concat = op "concat"
    totlen = typeSizeOf $ T_Tuple $ map fst l

check_concat_len :: Integer -> App ()
check_concat_len totlen =
  case totlen <= 4096 of
    True -> nop
    False -> bad $ "concat too big: 4096 < " <> texty totlen

cdigest :: [(DLType, App ())] -> App ()
cdigest l = cconcatbs l >> op "keccak256"

csubstring :: SrcLoc -> Integer -> Integer -> App ()
csubstring at b c =
  case b < 256 && c < 256 of
    True -> do
      code "substring" [tint at b, tint at c]
    False -> do
      cl $ DLL_Int sb b
      cl $ DLL_Int sb c
      op "substring3"

computeSubstring :: [DLType] -> Integer -> (DLType, Integer, Integer)
computeSubstring ts idx = (t, start, end)
  where
    szs = map typeSizeOf ts
    starts = scanl (+) 0 szs
    ends = zipWith (+) szs starts
    idx' = fromIntegral idx
    tse = zip3 ts starts ends
    (t, start, end) =
      case atMay tse idx' of
        Nothing -> impossible "bad idx"
        Just x -> x

cfor :: Integer -> (App () -> App ()) -> App ()
cfor maxi body = do
  top_lab <- freshLabel
  end_lab <- freshLabel
  salloc $ \idxl -> do
    let load_idx = code "load" [texty idxl]
    cl $ DLL_Int sb 0
    code "store" [texty idxl]
    label top_lab
    load_idx
    cl $ DLL_Int sb maxi
    op "<"
    code "bz" [end_lab]
    body load_idx
    load_idx
    cl $ DLL_Int sb 1
    op "+"
    code "store" [texty idxl]
    bad "backwards jump"
    code "b" [top_lab]
  label end_lab

doArrayRef :: SrcLoc -> DLArg -> Bool -> Either DLArg (App ()) -> App ()
doArrayRef at aa frombs ie = do
  let (t, _) = typeArray aa
  let tsz = typeSizeOf t
  ca aa
  let ie' =
        case ie of
          Left ia -> ca ia
          Right x -> x
  case t of
    T_Bool -> do
      case ie of
        Left (DLA_Literal (DLL_Int _ ii)) | ii < 256 -> do
          code "byteget" [texty ii]
        _ -> do
          ie'
          op "byteget2"
      case frombs of
        True -> nop
        False -> ctobs T_Bool
    _ -> do
      case ie of
        Left (DLA_Literal (DLL_Int _ ii)) -> do
          let start = ii * tsz
          let end = start + tsz
          csubstring at start end
        _ -> do
          cl $ DLL_Int sb tsz
          ie'
          op "*"
          op "dup"
          cl $ DLL_Int sb tsz
          op "+"
          op "substring3"
      case frombs of
        True -> cfrombs t
        False -> nop

cla :: DLLargeArg -> App ()
cla = \case
  DLLA_Array t as ->
    case t of
      T_Bool ->
        case cas_boolbs as of
          Nothing -> normal
          Just x -> cl $ DLL_Bytes x
      _ -> normal
    where
      normal = cconcatbs $ map (\a -> (t, ca a)) as
  DLLA_Tuple as ->
    cconcatbs $ map (\a -> (argTypeOf a, ca a)) as
  DLLA_Obj m ->
    cconcatbs $ map (\a -> (argTypeOf a, ca a)) $ map snd $ M.toAscList m
  DLLA_Data tm vt va -> do
    let mvti = find ((== vt) . fst . fst) $ zip (M.toAscList tm) [0 ..]
    let vti =
          case mvti of
            Just (_, x) -> x
            Nothing -> impossible $ "dla_data"
    cl $ DLL_Int sb vti
    ca va
    let vlen = 1 + typeSizeOf (argTypeOf va)
    op "concat"
    let dlen = typeSizeOf $ T_Data tm
    let zlen = fromIntegral $ dlen - vlen
    let zbs = B.replicate zlen (toEnum 0)
    cl $ DLL_Bytes zbs
    op "concat"
    check_concat_len dlen

ce :: DLExpr -> App ()
ce = \case
  DLE_Arg _ a -> ca a
  DLE_LArg _ a -> cla a
  DLE_Impossible at msg -> expect_thrown at $ Err_Impossible msg
  DLE_PrimOp _ p args -> cprim p args
  DLE_ArrayRef at aa ia -> doArrayRef at aa True (Left ia)
  DLE_ArraySet at aa ia va -> do
    let (t, alen) = typeArray aa
    case t of
      T_Bool -> do
        ca aa
        case ia of
          DLA_Literal (DLL_Int _ ii) | ii < 256 -> do
            ca va
            code "byteset" [texty ii]
          _ -> do
            ca ia
            ca va
            op "byteset2"
      _ -> do
        let tsz = typeSizeOf t
        let (before, after) =
              case ia of
                DLA_Literal (DLL_Int _ ii) -> (b, a)
                  where
                    start = ii * tsz
                    end = start + tsz
                    b = csubstring at 0 start
                    a = csubstring at end (alen * tsz)
                _ -> (b, a)
                  where
                    b = do
                      cl $ DLL_Int sb 0
                      cl $ DLL_Int sb tsz
                      ca ia
                      op "*"
                      op "substring3"
                    a = do
                      cl $ DLL_Int sb tsz
                      op "dup"
                      ca ia
                      op "*"
                      op "+"
                      cl $ DLL_Int sb (alen * tsz)
                      op "substring3"
        small_aa <- argSmall aa
        case small_aa of
          False -> do
            ca aa
            op "dup"
            -- [ aa, aa, ... ]
            before
            -- [ before, aa, ... ]
            ca va
            ctobs t
            -- [ va, before, aa, ... ]
            op "concat"
            -- [ before', aa, ... ]
            op "swap"
            -- [ aa, before', ... ]
            after
            -- [ after, before', ... ]
            op "concat"
          -- [ aa', ... ]
          True -> do
            ca aa >> before
            ca va
            ctobs t
            op "concat"
            ca aa >> after
            op "concat"
  DLE_ArrayConcat _ x y -> do
    let (xt, xlen) = typeArray x
    let (_, ylen) = typeArray y
    ca x
    ca y
    check_concat_len $ (xlen + ylen) * typeSizeOf xt
    op "concat"
  DLE_ArrayZip at x y -> do
    let xsz = typeSizeOf $ argTypeOf x
    let ysz = typeSizeOf $ argTypeOf y
    let (_, xlen) = typeArray x
    check_concat_len $ xsz + ysz
    salloc $ \ansl -> do
      cl $ DLL_Bytes ""
      code "store" [texty ansl]
      cfor xlen $ \load_idx -> do
        code "load" [texty ansl]
        doArrayRef at x False $ Right load_idx
        doArrayRef at y False $ Right load_idx
        op "concat"
        op "concat"
        code "store" [texty ansl]
      code "load" [texty ansl]
  DLE_TupleRef at ta idx -> do
    let ts = typeTupleTypes ta
    let (t, start, end) = computeSubstring ts idx
    ca ta
    csubstring at start end
    cfrombs t
  DLE_ObjectRef at oa f -> do
    let fts = typeObjectTypes oa
    let fidx = fromIntegral $ fromMaybe (impossible "bad field") $ findIndex ((== f) . fst) fts
    let (t, start, end) = computeSubstring (map snd fts) fidx
    ca oa
    csubstring at start end
    cfrombs t
  DLE_Interact {} -> impossible "consensus interact"
  DLE_Digest _ args -> cdigest $ map go args
    where
      go a = (argTypeOf a, ca a)
  DLE_Transfer _ who amt -> do
    txni <- talloc
    code "gtxn" [texty txni, "TypeEnum"]
    code "int" ["pay"]
    eq_or_fail
    code "gtxn" [texty txni, "Receiver"]
    ca who
    eq_or_fail
    code "gtxn" [texty txni, "Amount"]
    ca amt
    eq_or_fail
    code "gtxn" [texty txni, "Sender"]
    code "byte" [tContractAddr]
    cfrombs T_Address
    eq_or_fail
  DLE_Claim at fs t a mmsg -> do
    comment $ texty mmsg
    comment $ texty $ unsafeRedactAbsStr $ show at
    comment $ texty $ unsafeRedactAbsStr $ show fs
    case t of
      CT_Assert -> impossible "assert"
      CT_Assume -> check
      CT_Require -> check
      CT_Possible -> impossible "possible"
      CT_Unknowable {} -> impossible "unknowable"
    where
      check = ca a >> or_fail
  DLE_Wait {} -> nop
  DLE_PartSet _ _ a -> ca a

doSwitch :: (a -> App ()) -> SrcLoc -> DLVar -> SwitchCases a -> App ()
doSwitch ck at dv csm = do
  end_lab <- freshLabel
  let cm1 ((_vn, (mov, k)), vi) = do
        next_lab <- freshLabel
        ca $ DLA_Var dv
        code "byteget" ["0"]
        cl $ DLL_Int sb vi
        op "=="
        code "bz" [next_lab]
        case mov of
          Nothing -> ck k
          Just vv -> do
            salloc $ \loc -> do
              ca $ DLA_Var dv
              let vt = argTypeOf $ DLA_Var vv
              csubstring at 1 (1 + typeSizeOf vt)
              cfrombs vt
              code "store" [texty loc]
              store_let vv True (code "load" [texty loc]) $
                ck k
        label next_lab
  mapM_ cm1 $ zip (M.toAscList csm) [0 ..]
  label end_lab

cm :: App () -> PLCommon -> App ()
cm km = \case
  DL_Nop _ -> km
  DL_Let _ PV_Eff de -> ce de >> km
  DL_Let _ (PV_Let PL_Once dv) de -> do
    sm <- exprSmall de
    store_let dv sm (ce de) km
  DL_Let _ (PV_Let PL_Many dv) de -> do
    sm <- exprSmall de
    case sm of
      True ->
        store_let dv True (ce de) km
      False ->
        salloc $ \loc -> do
          let loct = texty loc
          ce de
          code "store" [loct]
          store_let dv True (code "load" [loct]) km
  DL_ArrayMap at ansv aa lv (DLinBlock _ _ body ra) -> do
    let anssz = typeSizeOf $ argTypeOf $ DLA_Var ansv
    let (_, xlen) = typeArray aa
    check_concat_len anssz
    salloc $ \ansl -> do
      cl $ DLL_Bytes ""
      code "store" [texty ansl]
      cfor xlen $ \load_idx -> do
        code "load" [texty ansl]
        doArrayRef at aa True $ Right load_idx
        salloc $ \lvl -> do
          code "store" [texty lvl]
          store_let lv True (code "load" [texty lvl]) $ do
            cp (ca ra) body
        op "concat"
        code "store" [texty ansl]
      store_let ansv True (code "load" [texty ansl]) km
  DL_ArrayReduce at ansv aa za av lv (DLinBlock _ _ body ra) -> do
    let (_, xlen) = typeArray aa
    salloc $ \ansl -> do
      ca za
      code "store" [texty ansl]
      store_let av True (code "load" [texty ansl]) $ do
        cfor xlen $ \load_idx -> do
          doArrayRef at aa True $ Right load_idx
          salloc $ \lvl -> do
            code "store" [texty lvl]
            store_let lv True (code "load" [texty lvl]) $ do
              cp (ca ra) body
          code "store" [texty ansl]
        store_let ansv True (code "load" [texty ansl]) km
  DL_Var _ dv ->
    salloc $ \loc -> do
      store_var dv loc $
        store_let dv True (code "load" [texty loc]) $
          km
  DL_Set _ dv da -> do
    loc <- lookup_var dv
    ca da
    code "store" [texty loc]
    km
  DL_LocalIf _ a tp fp -> do
    ca a
    false_lab <- freshLabel
    join_lab <- freshLabel
    code "bz" [false_lab]
    cp (return ()) tp
    code "b" [join_lab]
    label false_lab
    cp (return ()) fp
    label join_lab
    km
  DL_LocalSwitch at dv csm -> do
    doSwitch (cp (return ())) at dv csm
    km

cp :: App () -> PLTail -> App ()
cp km = \case
  DT_Return _ -> km
  DT_Com m k -> cm (cp km k) m

ct :: CTail -> App ()
ct = \case
  CT_Com m k -> cm (ct k) m
  CT_If _ a tt ft -> do
    ca a
    false_lab <- freshLabel
    code "bz" [false_lab]
    ct tt
    label false_lab
    ct ft
  CT_Switch at dv csm -> doSwitch ct at dv csm
  CT_Jump at which _ (DLAssignment asnm) -> do
    Env {..} <- ask
    let Shared {..} = eShared
    case M.lookup which sHandlers of
      Just (C_Loop _ _ lcvars t) -> do
        let timev = fromMaybe (impossible "no timev") emTimev
        let llc v =
              case find ((== v) . snd) lcvars of
                Nothing -> impossible $ "no loop var"
                Just (lc, _) -> lc
        rhor <- liftIO $ newIORef mempty
        ntvr <- liftIO $ newIORef Nothing
        let go (v, a) = do
              v' <- allocVar v
              liftIO $ modifyIORef rhor (M.insert v v')
              when (a == DLA_Var timev) $ do
                liftIO $ writeIORef ntvr $ Just v
              let lc = llc v
              let de = DLE_Arg at a
              let m = DL_Let at (PV_Let lc v') de
              return m
        nms <- mapM go $ M.toList asnm
        rho <- liftIO $ readIORef rhor
        let t_subst = subst_ rho t
        ntv <- liftIO $ readIORef ntvr
        let new_timev = fromMaybe (impossible "no new_timev") ntv
        let t_subst' = foldl' (flip CT_Com) t_subst nms
        local (\e -> e { eWhich = which
                       , emTimev = Just new_timev }) $ do
          ct t_subst'
      _ ->
        impossible "bad jump"
  CT_From _ msvs -> do
    check_nextSt
    halt_should_be isHalt
    where
      (isHalt, check_nextSt) =
        case msvs of
          --- XXX fix this so it makes sure it is zero bytes
          Nothing -> (True, return ())
          Just svs -> (False, ck)
            where
              ck = do
                Env {..} <- ask
                let timev = fromMaybe (impossible "no timev") emTimev
                cstate HM_Set $ map snd $ dvdeletep timev svs
                code "arg" [texty argNextSt]
                eq_or_fail

data HashMode
  = HM_Set
  | HM_Check Int
  deriving (Eq, Show)

cstate :: HashMode -> [DLArg] -> App ()
cstate hm svs = do
  comment ("compute state in " <> texty hm)
  which <-
    case hm of
      HM_Set -> do
        Env {..} <- ask
        return eWhich
      HM_Check prev ->
        return prev
  let go a = (argTypeOf a, ca a)
  let whicha w = DLA_Literal $ DLL_Int sb $ fromIntegral w
  cdigest $ map go $ whicha which : svs

halt_should_be :: Bool -> App ()
halt_should_be b = do
  code "arg" [texty argHalts]
  cfrombs T_Bool
  cl $ DLL_Bool b
  eq_or_fail
  code "b" ["done"]

-- Intialization:
--
-- 0. Alice creates the application; gets Id
-- 1. Alice creates the contract account; embeds Id; gets Me
-- 2. Alice creates the handler contracts; embeds Id & Me; gets H_i
-- 3. Alice updates the application; embedding Me & H_i

-- Template
tApplicationID :: LT.Text
tApplicationID = template "ApplicationID"

tContractAddr :: LT.Text
tContractAddr = template "ContractAddr"

tDeployer :: LT.Text
tDeployer = template "Deployer"

-- State:
keyHalts :: B.ByteString
keyHalts = "h"

keyState :: B.ByteString
keyState = "s"

keyLast :: B.ByteString
keyLast = "l"

-- Txns:
-- 0   : Application call
-- 1   : Transfer fee to the handler account
-- 2   : Zero from handler account
-- 3   : Transfer to contract account
-- 4.. : Transfers from contract to user
txnAppl :: Word8
txnAppl = 0

txnToHandler :: Word8
txnToHandler = txnAppl + 1

txnFromHandler :: Word8
txnFromHandler = txnToHandler + 1

txnToContract :: Word8
txnToContract = txnFromHandler + 1

txnFromContract0 :: Word8
txnFromContract0 = txnToContract + 1

-- Args:
-- 0   : Previous state
-- 1   : Next state
-- 2   : Handler halts
-- 3   : Fee amount
-- 4   : Last round
-- 5.. : Handler arguments
stdArgTypes :: [DLType]
stdArgTypes = [T_Digest, T_Digest, T_Bool, T_UInt, T_UInt]

argPrevSt :: Word8
argPrevSt = 0

argNextSt :: Word8
argNextSt = argPrevSt + 1

argHalts :: Word8
argHalts = argNextSt + 1

argFeeAmount :: Word8
argFeeAmount = argHalts + 1

argLast :: Word8
argLast = argFeeAmount + 1

argFirstUser :: Word8
argFirstUser = argLast + 1

lookup_sender :: App ()
lookup_sender = code "gtxn" [texty txnToContract, "Sender"]

lookup_last :: App ()
lookup_last = code "arg" [texty argLast] >> cfrombs T_UInt

lookup_fee_amount :: App ()
lookup_fee_amount = code "arg" [texty argFeeAmount] >> cfrombs T_UInt

std_footer :: App ()
std_footer = do
  label "done"
  cl $ DLL_Int sb 1
  op "return"

runApp :: Shared -> Int -> Lets -> Maybe DLVar -> App () -> IO TEALs
runApp eShared eWhich eLets emTimev m = do
  eLabelR <- newIORef 0
  eOutputR <- newIORef mempty
  let eHP = 0
  let eSP = 255
  eTxnsR <- newIORef $ txnFromContract0 - 1
  let eVars = mempty
  -- Everything initial is small
  let eLetSmalls = M.map (\_ -> True) eLets
  flip runReaderT (Env {..}) m
  readIORef eOutputR

ch :: Shared -> Int -> CHandler -> IO (Maybe (Integer, TEALs))
ch _ _ (C_Loop {}) = return $ Nothing
ch eShared eWhich (C_Handler _ int last_timemv from prev svs_ msg amtv timev body) =
  let svs = dvdeletem last_timemv svs_
   in fmap Just $
        fmap ((,) (typeSizeOf $ T_Tuple $ (++) stdArgTypes $ map varType $ svs ++ msg)) $ do
          let mkarg dv@(DLVar _ _ t _) (i :: Int) = (dv, code "arg" [texty i] >> cfrombs t)
          let args = svs <> msg
          let argFirstUser' = fromIntegral argFirstUser
          let eLets0 = M.fromList $ zipWith mkarg args [argFirstUser' ..]
          let argCount = argFirstUser' + length args
          let eLets1 = M.insert from lookup_sender eLets0
          let lookup_txn_value = do
                code "gtxn" [texty txnToContract, "Amount"]
                lookup_fee_amount
                op "-"
          let eLets2 = M.insert amtv lookup_txn_value eLets1
          let eLets3 = M.insert timev (bad $ texty $ "handler " <> show eWhich <> " cannot inspect round: " <> show (pretty timev)) eLets2
          let eLets4 = case last_timemv of
                Nothing -> eLets3
                Just x -> M.insert x lookup_last eLets3
          let eLets = eLets4
          runApp eShared eWhich eLets (Just timev) $ do
            comment ("Handler " <> texty eWhich)
            comment "Check txnAppl"
            code "gtxn" [texty txnAppl, "TypeEnum"]
            code "int" ["appl"]
            eq_or_fail
            code "gtxn" [texty txnAppl, "ApplicationID"]
            --- XXX Make this int
            code "byte" [tApplicationID]
            cfrombs T_UInt
            eq_or_fail

            comment "Check txnToHandler"
            code "gtxn" [texty txnToHandler, "TypeEnum"]
            code "int" ["pay"]
            eq_or_fail
            code "gtxn" [texty txnToHandler, "Receiver"]
            code "txn" ["Sender"]
            eq_or_fail
            code "gtxn" [texty txnToHandler, "Amount"]
            code "gtxn" [texty txnFromHandler, "Fee"]
            eq_or_fail

            comment "Check txnToContract"
            code "gtxn" [texty txnToContract, "TypeEnum"]
            code "int" ["pay"]
            eq_or_fail
            code "gtxn" [texty txnToContract, "Receiver"]
            code "byte" [tContractAddr]
            eq_or_fail

            comment "Check txnFromHandler (us)"
            code "txn" ["GroupIndex"]
            cl $ DLL_Int sb $ fromIntegral $ txnFromHandler
            eq_or_fail
            code "txn" ["TypeEnum"]
            code "int" ["pay"]
            eq_or_fail
            code "txn" ["Amount"]
            cl $ DLL_Int sb $ 0
            eq_or_fail
            code "txn" ["Receiver"]
            code "gtxn" [texty txnToHandler, "Sender"]
            eq_or_fail
            code "txn" ["NumArgs"]
            cl $ DLL_Int sb $ fromIntegral $ argCount
            eq_or_fail
            cstate (HM_Check prev) $ map DLA_Var $ dvdeletem last_timemv svs
            code "arg" [texty argPrevSt]
            eq_or_fail

            --- XXX close remainder to is deployer if halts, zero otherwise

            comment "Run body"
            ct body

            txns <- how_many_txns
            comment "Check GroupSize"
            code "global" ["GroupSize"]
            cl $ DLL_Int sb $ fromIntegral $ 1 + txns
            eq_or_fail

            lookup_fee_amount
            csum_ $ map (\i -> code "gtxn" [texty i, "Fee"]) [txnFromContract0 .. txns]
            eq_or_fail

            comment "Check time limits"
            -- We don't need to look at timev because the range of valid rounds
            -- that a txn is valid within is built-in to Algorand, so rather than
            -- checking that ( last_timev + from <= timev <= last_timev + to ), we
            -- just check that FirstValid = last_time + from, etc.
            (case last_timemv of
               Nothing -> return ()
               Just last_timev -> do
                 let check_time f = \case
                       [] -> nop
                       as -> do
                         ca $ DLA_Var last_timev
                         csum as
                         op "+"
                         let go i = do
                               op "dup"
                               code "gtxn" [texty i, f]
                               eq_or_fail
                         forM_ [0 .. txns] go
                         op "pop"
                 let CBetween ifrom ito = int
                 check_time "FirstValid" ifrom
                 check_time "LastValid" ito)

            std_footer

type Disp = String -> T.Text -> IO ()

compile_algo :: Disp -> PLProg -> IO ConnectorInfo
compile_algo disp pl = do
  let PLProg _at (PLOpts {..}) _dli _ cpp = pl
  -- We ignore dli, because it can only contain a binding for the creation
  -- time, which is the previous time of the first message, and these
  -- last_timevs are never included in svs on Algorand.
  let CPProg _at (CHandlers hm) = cpp
  resr <- newIORef mempty
  let sHandlers = hm
  sFailedR <- newIORef False
  let sCounterR = plo_counter
  let shared = Shared {..}
  let addProg lab t = do
        modifyIORef resr (M.insert (T.pack lab) $ Aeson.String t)
        disp lab t
  hm_res <- forM (M.toAscList hm) $ \(hi, hh) -> do
    mht <- ch shared hi hh
    case mht of
      Nothing -> return (Aeson.Null, Aeson.Number 0, return ())
      Just (az, ht) -> do
        let lab = "m" <> show hi
        let t = render ht
        disp lab t
        return
          ( Aeson.String t
          , Aeson.Number $ fromInteger az
          , do
              code "gtxn" [texty txnFromHandler, "Sender"]
              code "byte" [template $ LT.pack lab]
              op "=="
              op "||"
          )
  let (steps_, stepargs_, hchecks) = unzip3 hm_res
  let steps = Aeson.Null : steps_
  let stepargs = Aeson.Number 0 : stepargs_
  modifyIORef resr $ M.insert "steps" $ aarray steps
  modifyIORef resr $ M.insert "stepargs" $ aarray stepargs
  let howManySteps =
        length $
          filter
            (\case
               Aeson.String _ -> True
               _ -> False)
            steps
  let simple m = runApp shared 0 mempty Nothing $ m >> std_footer
  app0m <- simple $ do
    comment "Check that we're an App"
    code "txn" ["TypeEnum"]
    code "int" ["appl"]
    eq_or_fail
    check_rekeyto
    code "txn" ["Sender"]
    code "byte" [tDeployer]
    eq_or_fail
    code "txn" ["ApplicationID"]
    code "bz" ["init"]
    code "global" ["GroupSize"]
    cl $ DLL_Int sb $ fromIntegral $ 2 + howManySteps
    eq_or_fail
    --- XXX can we constrain the other txns to transfer the correct amount?
    code "txn" ["OnCompletion"]
    code "int" ["UpdateApplication"]
    eq_or_fail
    --- XXX if firstMsg mode, then paste a version of handler 1 right here
    app_global_put keyState $ do
      cstate HM_Set []
    app_global_put keyLast $ do
      code "global" ["Round"]
    app_global_put keyHalts $ do
      cl $ DLL_Bool $ False
    code "b" ["done"]
    label "init"
    code "global" ["GroupSize"]
    cl $ DLL_Int sb $ 1
    eq_or_fail
    code "txn" ["OnCompletion"]
    code "int" ["NoOp"]
    eq_or_fail
    code "b" ["done"]
  appm <- simple $ do
    comment "Check that we're an App"
    code "txn" ["TypeEnum"]
    code "int" ["appl"]
    eq_or_fail
    check_rekeyto
    comment "Check that everyone's here"
    code "global" ["GroupSize"]
    cl $ DLL_Int sb $ fromIntegral $ txnFromContract0
    op ">="
    or_fail
    comment "Check txnAppl (us)"
    code "txn" ["GroupIndex"]
    cl $ DLL_Int sb $ fromIntegral $ txnAppl
    eq_or_fail
    comment "Check txnFromHandler"
    cl $ DLL_Bool $ False
    forM_ hchecks id
    or_fail
    app_global_get keyState
    code "gtxna" [texty txnFromHandler, "Args", texty argPrevSt]
    cfrombs T_Digest
    eq_or_fail
    app_global_get keyLast
    code "gtxna" [texty txnFromHandler, "Args", texty argLast]
    cfrombs T_UInt
    eq_or_fail
    comment "Don't check anyone else, because Handler does"
    comment "Update state"
    app_global_put keyState $ do
      code "gtxna" [texty txnFromHandler, "Args", texty argNextSt]
      cfrombs T_Digest
    app_global_put keyLast $ do
      code "global" ["Round"]
    --- XXX we don't actually need halts
    app_global_put keyHalts $ do
      code "gtxna" [texty txnFromHandler, "Args", texty argHalts]
      cfrombs T_Bool
    app_global_get keyHalts
    code "bnz" ["halted"]
    code "txn" ["OnCompletion"]
    code "int" ["NoOp"]
    eq_or_fail
    code "b" ["done"]
    label "halted"
    code "txn" ["OnCompletion"]
    code "int" ["DeleteApplication"]
    eq_or_fail
    code "b" ["done"]
  clearm <- simple $ do
    comment "We're alone"
    code "global" ["GroupSize"]
    cl $ DLL_Int sb $ 1
    eq_or_fail
    comment "We're halted"
    app_global_get keyHalts
    cl $ DLL_Bool $ True
    eq_or_fail
    code "b" ["done"]
  -- XXX ctc needs to allow deployer to get back minimum balance
  ctcm <- simple $ do
    comment "Check size"
    code "global" ["GroupSize"]
    cl $ DLL_Int sb $ fromIntegral $ txnFromContract0
    op ">="
    or_fail
    comment "Check txnAppl"
    code "gtxn" [texty txnAppl, "TypeEnum"]
    code "int" ["appl"]
    eq_or_fail
    code "gtxn" [texty txnAppl, "ApplicationID"]
    code "byte" [tApplicationID]
    cfrombs T_UInt
    eq_or_fail
    comment "Don't check anything else, because app does"
    comment "Check us"
    code "txn" ["TypeEnum"]
    code "int" ["pay"]
    eq_or_fail
    check_rekeyto
    code "txn" ["CloseRemainderTo"]
    code "global" ["ZeroAddress"]
    eq_or_fail
    code "txn" ["GroupIndex"]
    cl $ DLL_Int sb $ fromIntegral $ txnFromContract0
    op ">="
    or_fail
    code "b" ["done"]
  addProg "appApproval0" $ render app0m
  addProg "appApproval" $ render appm
  addProg "appClear" $ render clearm
  addProg "ctc" $ render ctcm
  res0 <- readIORef resr
  sFailed <- readIORef sFailedR
  let res1 = M.insert "unsupported" (Aeson.Bool sFailed) res0
  -- let res2 = M.insert "deployMode" (CI_Text $ T.pack $ show plo_deployMode) res1
  return $ Aeson.Object $ HM.fromList $ M.toList res1

connect_algo :: Connector
connect_algo = Connector {..}
  where
    conName = "ALGO"
    conCons DLC_UInt_max = DLL_Int sb $ 2 ^ (64 :: Integer) - 1
    conGen moutn pl = do
      let disp which c =
            case moutn of
              Nothing -> return ()
              Just outn ->
                TIO.writeFile (outn $ T.pack $ which <> ".teal") c
      res <- compile_algo disp pl
      return $ res
