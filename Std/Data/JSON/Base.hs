{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}


module Std.Data.JSON.Base where

import qualified Std.Data.Vector.FlatMap as FM
import qualified Std.Data.Vector         as V
import qualified Std.Data.Text           as T
import qualified Control.Monad.Fail      as Fail
import           Data.Scientific         (Scientific)
import qualified Std.Data.Builder        as B
import qualified Std.Data.TextBuilder    as TB
import qualified Std.Data.Parser         as P
import           Std.Data.JSON.Value
import Data.Data
import Data.Typeable
import GHC.Generics

--------------------------------------------------------------------------------


parse :: FromJSON a => V.Bytes -> Either JSONParseError a
parse = undefined

parseChunks :: (FromJSON a, Monad m) => m V.Bytes -> V.Bytes -> m (V.Bytes, Either JSONParseError a)
parseChunks = undefined

--------------------------------------------------------------------------------

-- | Elements of a JSON path used to describe the location of an error.
data Path
    = Key T.Text
        -- ^ JSON path element of a key into an object,
        -- \"object.key\".
    | Index {-# UNPACK #-} !Int
        -- ^ JSON path element of an index into an
        -- array, \"array[index]\".
  deriving (Eq, Show, Typeable, Ord)

data JSONParseError = ValueParseError T.Text | JSONParseError [Path] T.Text

instance Show JSONParseError where
    -- TODO use standard format
    show (ValueParseError msg) = "ValueParseError: " ++ T.unpack msg
    show (JSONParseError paths msg) = T.unpack . TB.buildText $ do
        "JSONParseError: $"
        mapM_ renderPath (reverse paths)
        ": "
        TB.text msg
      where
        renderPath (Index ix) = TB.char7 '[' >> TB.int ix >> TB.char7 ']'
        renderPath (Key k) = TB.char7 '.' >> TB.text k


type ParserStep r = [Path] -> Either JSONParseError r

-- | 'Parser' for parsing result from JSON 'Value'.
newtype Parser a = Parser
    { runJSONParse :: forall r. (a -> ParserStep r) -> ParserStep r }

-- | Run a 'Parser' with a 'Either' result type.
parseEither :: (a -> Parser r) -> a -> Either JSONParseError r
{-# INLINE parseEither #-}
parseEither m v = runJSONParse (m v) (\ x _ -> Right x) []

instance Functor Parser where
    fmap f m = Parser (\ k -> runJSONParse m (k . f))
    {-# INLINE fmap #-}

instance Applicative Parser where
    pure a = Parser (\ k -> k a)
    {-# INLINE pure #-}
    (Parser f) <*> (Parser g) = Parser (\ k path ->
        f (\ f' _ ->  g (k . f') path) path)
    {-# INLINE (<*>) #-}

instance Monad Parser where
    (Parser f) >>= g = Parser (\ k path ->
        f (\ a _ -> runJSONParse (g a) k path) path)
    {-# INLINE (>>=) #-}
    return = pure
    {-# INLINE return #-}
    fail = Fail.fail
    {-# INLINE fail #-}

instance Fail.MonadFail Parser where
    fail msg = Parser (\ _ paths -> Left (JSONParseError paths (T.pack msg)))

failMsgs :: [T.Text] -> Parser a
failMsgs msgs = Parser (\ _ paths -> Left (JSONParseError paths (T.concat msgs)))

typeMismatch :: T.Text     -- ^ The name of the type you are trying to parse.
             -> Value      -- ^ The actual value encountered.
             -> Parser a
typeMismatch expected actual =
    failMsgs ["expected ", expected, ", encountered ", name]
  where
    name = case actual of
        Object _ -> "Object"
        Array _  -> "Array"
        String _ -> "String"
        Number _ -> "Number"
        Bool _   -> "Boolean"
        Null     -> "Null"


-- | Add JSON Path context to a parser
--
-- When parsing a complex structure, it helps to annotate (sub)parsers
-- with context, so that if an error occurs, you can find its location.
--
-- > withObject "Person" $ \o ->
-- >   Person
-- >     <$> o .: "name" <?> Key "name"
-- >     <*> o .: "age"  <?> Key "age"
--
-- (Standard methods like '(.:)' already do this.)
--
-- With such annotations, if an error occurs, you will get a JSON Path
-- location of that error.
(<?>) :: Parser a -> Path -> Parser a
{-# INLINE (<?>) #-}
(Parser p) <?> path = Parser (\ k paths -> p k (path:paths))
infixl 0 <?>

withBool :: (Bool -> Parser a) -> Value ->  Parser a
withBool f (Bool x)  = f x
withBool f v         = typeMismatch "Bool" v

withNumber :: (Scientific -> Parser a) -> Value ->  Parser a
withNumber f (Number x)  = f x
withNumber f v           = typeMismatch "Number" v

withString :: (T.Text -> Parser a) -> Value -> Parser a
withString f (String x)  = f x
withString f v           = typeMismatch "String" v

withArray :: (Array -> Parser a) -> Value -> Parser a
withArray f (Array arr)  = f arr
withArray f v            = typeMismatch "Array" v

withObject :: (Object -> Parser a) -> Value -> Parser a
withObject f (Object obj) = f obj
withObject f v            = typeMismatch "Object" v

-- | Decode a nested JSON-encoded string.
withEmbeddedJSON :: T.Text -> (Value -> Parser a) -> Value -> Parser a
withEmbeddedJSON _ innerParser (String txt) =
    either fail' innerParser $ parse (T.getUTF8Bytes txt)
  where
    fail' e = fail ("fail to parse embeded JSON field: " ++ show e)
withEmbeddedJSON name _ v = typeMismatch name v
{-# INLINE withEmbeddedJSON #-}

-- | Retrieve the value associated with the given key of an 'Object'.
-- The result is 'empty' if the key is not present or the value cannot
-- be converted to the desired type.
--
-- This accessor is appropriate if the key and value /must/ be present
-- in an object for it to be valid.  If the key and value are
-- optional, use '.:?' instead.
(.:) :: (FromJSON a) => Object -> T.Text -> Parser a
{-# INLINE (.:) #-}
(.:) = parseField parseJSON

-- | Retrieve the value associated with the given key of an 'Object'. The
-- result is 'Nothing' if the key is not present or if its value is 'Null',
-- or 'empty' if the value cannot be converted to the desired type.
--
-- This accessor is most useful if the key and value can be absent
-- from an object without affecting its validity.  If the key and
-- value are mandatory, use '.:' instead.
(.:?) :: (FromJSON a) => Object -> T.Text -> Parser (Maybe a)
{-# INLINE (.:?) #-}
(.:?) = parseFieldMaybe parseJSON

-- | Retrieve the value associated with the given key of an 'Object'.
-- The result is 'Nothing' if the key is not present or 'empty' if the
-- value cannot be converted to the desired type.
--
-- This differs from '.:?' by attempting to parse 'Null' the same as any
-- other JSON value, instead of interpreting it as 'Nothing'.
(.:!) :: (FromJSON a) => Object -> T.Text -> Parser (Maybe a)
{-# INLINE (.:!) #-}
(.:!) = parseFieldMaybe' parseJSON

parseField :: (Value -> Parser a)  -- ^ the field parser (value part of a key value pair)
           -> Object -> T.Text -> Parser a
parseField p obj key = case FM.lookup key obj of
    Just v -> p v <?> Key key
    _      -> fail (T.unpack . T.concat $ ["key ", key, " not present"])

-- | Variant of '.:?' with explicit parser function.
parseFieldMaybe :: (Value -> Parser a) -> Object -> T.Text -> Parser (Maybe a)
{-# INLINE parseFieldMaybe #-}
parseFieldMaybe p obj key = case FM.lookup key obj of
    Just Null -> pure Nothing
    Just v    -> Just <$> p v <?> Key key
    _         -> pure Nothing

-- | Variant of '.:!' with explicitliftParseJSON p (listParser p) parser function.
parseFieldMaybe' :: (Value -> Parser a) -> Object -> T.Text -> Parser (Maybe a)
{-# INLINE parseFieldMaybe' #-}
parseFieldMaybe' p obj key = case FM.lookup key obj of
    Just v  -> Just <$> p v <?> Key key
    _       -> pure Nothing

--------------------------------------------------------------------------------

class FromJSON a where
    parseJSON :: Value -> Parser a

instance FromJSON Value where
    {-# INLINE parseJSON #-}
    parseJSON = return

class ToJSON a where
    toJSON :: a -> Value
    buildJSON :: a -> B.Builder ()




