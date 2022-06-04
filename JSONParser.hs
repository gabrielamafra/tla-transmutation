{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module JSONParser where

import qualified Head as H
import Data.Aeson
import Data.List
import GHC.Generics
import qualified Data.ByteString.Lazy as B
import Control.Applicative

type Kind = String

jsonFile :: FilePath
jsonFile = "tla_specifications/TokenTransfer2.json"

data Spec = Spec [Module] deriving (Show,Generic)

data Module = Module String [Declaration] deriving (Show, Generic)

data Declaration = Declaration Kind String (Maybe Expression) | Ignored deriving (Show, Generic)
data Expression = ValEx TlaValue | NameEx String | OperEx String [Expression] | LetInEx [Declaration] Expression deriving (Show, Generic)
data TlaValue = TlaStr String | TlaBool Bool | TlaInt Integer | FullSet String deriving (Show, Generic)

instance FromJSON Spec where
    parseJSON = withObject "Spec" $ \obj -> do
      ms <- obj .: "modules"
      return (Spec ms)

instance FromJSON Module where
    parseJSON = withObject "Module" $ \obj -> do
      ds <- obj .: "declarations"
      i <- obj .: "name"
      return (Module i ds)

instance FromJSON Declaration where
  parseJSON = withObject "Declaration" $ \obj -> do
      src <- obj .: "source"
      filename <- case src of
        Object a -> a .: "filename"
        _ -> return "UNKNOWN"
      case filename :: String of
        "Functions"  -> return Ignored
        "SequencesExt"  -> return Ignored
        _            -> do k <- obj .: "kind"
                           n <- obj .: "name"
                           b <- obj .:? "body"
                           return (Declaration k n b)

instance FromJSON TlaValue where
    parseJSON = withObject "TlaValue" $ \obj -> do
      valueKind <- obj .: "kind"
      case valueKind of
        "TlaBool"           -> fmap TlaBool (obj .: "value")
        "TlaStr"            -> fmap TlaStr (obj .: "value")
        "TlaInt"            -> fmap TlaInt (obj .: "value")
        "TlaIntSet"         -> return (FullSet "Int")
        "TlaNatSet"         -> return (FullSet "Nat")
        "TlaBoolSet"        -> return (FullSet "Bool")
        _                   -> fail ("Unknown value kind: " ++ valueKind)

instance FromJSON Expression where
    parseJSON = withObject "Expression" $ \obj -> do
      exprKind <- obj .: "kind"
      case exprKind :: String of
        "ValEx" -> fmap ValEx (obj .: "value")
        "NameEx" -> fmap NameEx (obj .: "name")
        "OperEx" -> liftA2 OperEx (obj .: "oper") (obj .: "args")
        "LetInEx" -> liftA2 LetInEx (obj .: "decls") (obj .: "body")

notIgnored Ignored = False
notIgnored _ = True

convertSpec :: Spec -> Either String (H.Module, [H.Definition])
convertSpec (Spec [Module i ds]) = fmap (H.Module i [],) (mapM convertDefinitions (filter notIgnored ds))

convertDefinitions :: Declaration -> Either String H.Definition
convertDefinitions (Declaration k n body) = case body of
                                              Just b -> convertBody k n b
                                              Nothing -> case k of
                                                "TlaConstDecl" -> Right (H.Constants [n])
                                                "TlaVarDecl" -> Right (H.Variables [n])
                                                "OperEx" -> Left "OperEx needs body"
                                                _ -> Left ("Unknown kind" ++ show k ++ " body " ++ show body)

convertBody :: Kind -> String -> Expression -> Either String H.Definition
convertBody k i e = case k of
                      "OperEx" -> Right (H.Comment "A")
                      "TlaOperDecl" -> convertExpression e >>= \x -> Right (H.ActionDefinition i [] [] x)
                      _ -> Left ("Unknown body kind " ++ show k)


primed :: Expression -> Either String H.Identifier
primed (OperEx o [a]) = case o of
                         "PRIME" -> identifier a
                         _ -> Left ("Not prime operator: " ++ o)

identifier :: Expression -> Either String H.Identifier
identifier (NameEx i) = Right i

manyIdentifiers :: Expression -> Either String [H.Identifier]
manyIdentifiers (NameEx i) = Right [i]
manyIdentifiers (OperEx o as) = case o of
                                  "TUPLE" -> mapM identifier as
                                  _ -> Left ("Not tuple operator: " ++ o)

identifierFromString :: Expression -> Either String H.Identifier
identifierFromString (ValEx (TlaStr s)) = Right s

val :: TlaValue -> H.Value
val (TlaStr s) = H.Str s
val (TlaBool b) = H.Boolean b
val (TlaInt n) = H.Num n
val (FullSet s) = H.FullSet s

splits :: [a] -> [(a, a)]
splits [a, b] = [(a, b)]
splits (a:b:ts) = (a,b):splits ts

valueOperators :: [String]
valueOperators = ["TUPLE", "MINUS", "PLUS", "EXCEPT", "DOMAIN", "RECORD"]

valuePrefixes :: [String]
valuePrefixes = ["FUN_", "SET_", "INT_"]

convertValue :: Expression -> Either String H.Value
convertValue (NameEx i) = Right(H.Ref i)
convertValue (ValEx v) = Right(val v)
convertValue (OperEx o as) = case o of
                              "FUN_SET" -> case as of
                                [a1, a2] -> liftA2 H.FunSet (convertValue a1) (convertValue a2)
                              "FUN_APP" -> case as of
                                [a1, a2] -> liftA2 H.Index (convertValue a1) (convertValue a2)
                              "FUN_CTOR" -> case as of
                                [a1, a2, a3] -> liftA3 H.FunGen (identifier a1) (convertValue a2) (convertValue a3)
                              "SET_TIMES" -> case as of
                                [a1, a2] -> liftA2 H.SetTimes (convertValue a1) (convertValue a2)
                              "SET_ENUM" -> case as of
                                vs -> fmap H.Set (mapM convertValue vs)
                              "INT_RANGE" -> case as of
                                [a1, a2] -> liftA2 H.Range (convertValue a1) (convertValue a2)
                              "TUPLE" -> case as of
                                vs -> fmap H.Tuple (mapM convertValue vs)
                              "RECORD" -> case as of
                                vs -> fmap H.Record (convertRecordValues vs)
                              "MINUS" -> case as of
                                [a1, a2] -> liftA2 H.Sub (convertValue a1) (convertValue a2)
                              "PLUS" -> case as of
                                [a1, a2] -> liftA2 H.Add (convertValue a1) (convertValue a2)
                              "EXCEPT" -> case as of
                                (e:es) -> liftA2 H.Except (identifier e) (fmap splits (mapM convertValue es))
                              "DOMAIN" -> case as of
                                [a1] -> fmap H.Domain (convertValue a1)
                              "NE" -> case as of
                                [x1, x2] -> liftA2 H.Inequality (convertValue x1) (convertValue x2)
                              "EQ" -> case as of
                                [x1, x2] -> liftA2 H.Equality (convertValue x1) (convertValue x2)
                              "GT" -> case as of
                                [x1, x2] -> liftA2 H.Gt (convertValue x1) (convertValue x2)
                              "GE" -> case as of
                                [x1, x2] -> liftA2 H.Gte (convertValue x1) (convertValue x2)
                              "EXISTS3" -> case as of
                                [a1, a2, a3] -> liftA3 H.PExists (identifier a1) (convertValue a2) (convertValue a3)
                              "FORALL3" -> case as of
                                [a1, a2, a3] -> liftA3 H.PForAll (identifier a1) (convertValue a2) (convertValue a3)
                              "AND" -> case as of
                                es -> fmap H.And (mapM convertValue es)
                              "OR" -> case as of
                                es -> fmap H.Or (mapM convertValue es)
                              "NOT" -> case as of
                                [a] -> fmap H.Not (convertValue a)
                              "IF_THEN_ELSE" -> case as of
                                [a1, a2, a3] -> liftA3 H.If (convertValue a1) (convertValue a2) (convertValue a3)
                              "OPER_APP" -> case as of
                                (e:es) -> liftA2 H.ConditionCall (identifier e) (mapM convertValue es)
                              op -> Left ("Unknown value operator " ++ op)
convertValue (LetInEx ds b) = liftA2 H.Let (mapM convertDefinitions ds) (convertValue b)
-- convertValue e = Left ("Unexpected expression while converting value: " ++ show e)

convertAction :: Expression -> Either String H.Action
convertAction (OperEx o as) = case o of
                               "EXISTS3" -> case as of
                                 [a1, a2, a3] -> liftA3 H.Exists (identifier a1) (convertValue a2) (convertExpression a3)
                               "FORALL3" -> case as of
                                 [a1, a2, a3] -> liftA3 H.ForAll (identifier a1) (convertValue a2) (convertExpression a3)
                               "UNCHANGED" -> case as of
                                 [a] -> liftA H.Unchanged (manyIdentifiers a)
                               "AND" -> case as of
                                 es -> fmap H.ActionAnd (mapM convertExpression es)
                               "EQ" -> case as of
                                 [a1, a2] -> liftA2 H.Primed (primed a1) (convertValue a2)
                               op -> Left("Unknown action operator " ++ op)

convertExpression :: Expression -> Either String H.Action
convertExpression (OperEx o as) = if isPredicate (OperEx o as) then convertValue (OperEx o as) >>= \x -> Right(H.Condition x) else convertAction (OperEx o as)
convertExpression (ValEx v) =  convertValue (ValEx v) >>= \cv -> Right(H.Condition cv)

actionOperators :: [String]
actionOperators = ["PRIME", "UNCHANGED"]


isPredicate :: Expression -> Bool
isPredicate (OperEx o as) =  if o `elem` actionOperators then False else all isPredicate as
isPredicate _ = True

convertRecordValues :: [Expression] -> Either String [(H.Key, H.Value)]
convertRecordValues [] = Right []
convertRecordValues (k:v:vs) = do k <- identifierFromString k
                                  e <- convertValue v
                                  rs <- convertRecordValues vs
                                  return ((H.Key k, e):rs)

parseJson :: FilePath -> IO (Either String (H.Module, [H.Definition]))
parseJson file = do content <- B.readFile file
                    return ((eitherDecode content :: Either String Spec) >>= convertSpec)

-- main :: IO ()
-- main = do
--  d <- eitherDecode <$> B.readFile jsonFile
--  case d of
--   Left err -> putStrLn err
--   Right ps -> case convertSpec ps of
--     Left err -> putStrLn ("Error: " ++ err ++ show ps)
--     Right a -> print a
